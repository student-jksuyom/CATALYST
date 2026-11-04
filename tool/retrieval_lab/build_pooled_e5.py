"""Bake masked mean pooling + L2 normalisation into the e5 ONNX graph.

The app's encoder contract is (input_ids, attention_mask) -> sentence_embedding,
so the Dart inference code stays model-agnostic. Run from the project root:
    .venv\\Scripts\\python tool\\retrieval_lab\\build_pooled_e5.py
"""
import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

SRC = "tool/retrieval_lab/e5/model.onnx"
DST = "assets/models/catalyst_encoder_e5.onnx"

model = onnx.load(SRC)
graph = model.graph
opset = max(o.version for o in model.opset_import if o.domain in ("", "ai.onnx"))
print("opset", opset, "inputs", [i.name for i in graph.input], "outputs", [o.name for o in graph.output])
hidden = graph.output[0].name
assert opset == 11, "this builder targets the opset-11 export (axes are attributes)"

graph.initializer.append(numpy_helper.from_array(np.array(1e-9, dtype=np.float32), "pool_eps"))
# The app feeds only input_ids and attention_mask, so derive zero token types.
for item in [i for i in graph.input if i.name == "token_type_ids"]:
    graph.input.remove(item)
nodes = [
    helper.make_node("Shape", ["input_ids"], ["pool_ids_shape"]),
    helper.make_node(
        "ConstantOfShape",
        ["pool_ids_shape"],
        ["token_type_ids"],
        value=numpy_helper.from_array(np.array([0], dtype=np.int64)),
    ),
    helper.make_node("Cast", ["attention_mask"], ["pool_mask_f"], to=TensorProto.FLOAT),
    helper.make_node("Unsqueeze", ["pool_mask_f"], ["pool_mask_3d"], axes=[-1]),
    helper.make_node("Mul", [hidden, "pool_mask_3d"], ["pool_masked"]),
    helper.make_node("ReduceSum", ["pool_masked"], ["pool_sum"], axes=[1], keepdims=0),
    helper.make_node("ReduceSum", ["pool_mask_3d"], ["pool_count"], axes=[1], keepdims=0),
    helper.make_node("Max", ["pool_count", "pool_eps"], ["pool_count_safe"]),
    helper.make_node("Div", ["pool_sum", "pool_count_safe"], ["pool_mean"]),
    helper.make_node("LpNormalization", ["pool_mean"], ["sentence_embedding"], axis=1, p=2),
]
# Prepend the token_type_ids producer so the graph stays topologically sorted.
graph.node.insert(0, nodes[0])
graph.node.insert(1, nodes[1])
graph.node.extend(nodes[2:])
del graph.output[:]
graph.output.append(
    helper.make_tensor_value_info("sentence_embedding", TensorProto.FLOAT, ["batch", 384])
)
onnx.checker.check_model(model) if model.ByteSize() < 2**31 else None
onnx.save(model, DST)
print("saved", DST)


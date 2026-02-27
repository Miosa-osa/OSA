#!/usr/bin/env python3
"""
OSA Python Sidecar — semantic memory search via local embeddings.

Reads JSON-RPC requests from stdin (one per line), writes responses to stdout.
Model: all-MiniLM-L6-v2 (80MB, CPU, 384-dim vectors).
"""
import sys
import json
import numpy as np
from typing import Optional

# Lazy-loaded model
_model = None
_vectors = {}  # entry_id -> numpy array

def get_model():
    global _model
    if _model is None:
        import logging
        logging.basicConfig(stream=sys.stderr, level=logging.INFO)
        logger = logging.getLogger("osa-sidecar")
        logger.info("Loading embedding model all-MiniLM-L6-v2...")
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer('all-MiniLM-L6-v2')
        logger.info("Model loaded successfully")
    return _model

def handle_ping(params):
    return "pong"

def handle_embed(params):
    text = params.get("text", "")
    if not text:
        raise ValueError("missing text param")
    model = get_model()
    embedding = model.encode(text, normalize_embeddings=True)
    return {"embedding": embedding.tolist()}

def handle_search(params):
    """Search stored vectors for the most similar entries to a query."""
    query = params.get("query", "")
    top_k = params.get("top_k", 10)
    if not query:
        raise ValueError("missing query param")
    if not _vectors:
        return {"results": []}

    model = get_model()
    query_vec = model.encode(query, normalize_embeddings=True)

    # Compute cosine similarity against all stored vectors
    scores = []
    for entry_id, vec in _vectors.items():
        # Both vectors are normalized, so dot product = cosine similarity
        similarity = float(np.dot(query_vec, vec))
        scores.append({"id": entry_id, "score": round(similarity, 4)})

    # Sort by score descending, return top_k
    scores.sort(key=lambda x: x["score"], reverse=True)
    return {"results": scores[:top_k]}

def handle_reindex(params):
    """Receive all memory entries and rebuild the vector store."""
    global _vectors
    entries = params.get("entries", [])
    if not entries:
        _vectors = {}
        return {"indexed": 0}

    model = get_model()
    texts = [e.get("content", "") for e in entries]
    ids = [e.get("id", str(i)) for i, e in enumerate(entries)]

    # Batch encode all entries
    embeddings = model.encode(texts, normalize_embeddings=True, show_progress_bar=False)

    _vectors = {}
    for entry_id, vec in zip(ids, embeddings):
        _vectors[entry_id] = vec

    return {"indexed": len(_vectors)}

def handle_similarity(params):
    """Compute cosine similarity between two texts."""
    text_a = params.get("text_a", "")
    text_b = params.get("text_b", "")
    if not text_a or not text_b:
        raise ValueError("missing text_a or text_b param")

    model = get_model()
    vecs = model.encode([text_a, text_b], normalize_embeddings=True)
    similarity = float(np.dot(vecs[0], vecs[1]))
    return {"similarity": round(similarity, 4)}

HANDLERS = {
    "ping": handle_ping,
    "embed": handle_embed,
    "search": handle_search,
    "reindex": handle_reindex,
    "similarity": handle_similarity,
}

def process_request(line: str) -> str:
    """Process a single JSON-RPC request line and return a response line."""
    try:
        req = json.loads(line)
    except json.JSONDecodeError as e:
        return json.dumps({"id": None, "error": {"code": -32700, "message": f"parse error: {e}"}})

    req_id = req.get("id")
    method = req.get("method", "")
    params = req.get("params", {})

    handler = HANDLERS.get(method)
    if handler is None:
        return json.dumps({"id": req_id, "error": {"code": -32601, "message": f"unknown method: {method}"}})

    try:
        result = handler(params)
        return json.dumps({"id": req_id, "result": result})
    except Exception as e:
        return json.dumps({"id": req_id, "error": {"code": -1, "message": str(e)}})

def main():
    """Main loop: read JSON-RPC from stdin, write responses to stdout."""
    import logging
    logging.basicConfig(stream=sys.stderr, level=logging.INFO)
    logger = logging.getLogger("osa-sidecar")
    logger.info("OSA Python sidecar starting...")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        response = process_request(line)
        sys.stdout.write(response + "\n")
        sys.stdout.flush()

    logger.info("OSA Python sidecar shutting down (stdin closed)")

if __name__ == "__main__":
    main()

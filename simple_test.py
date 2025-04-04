#!/usr/bin/env python3
"""Very simple FastAPI test to verify it's working."""

from fastapi import FastAPI
import uvicorn

app = FastAPI()

@app.get("/")
async def root():
    return {"message": "Simple FastAPI test is working"}

@app.get("/health")
async def health():
    return {"status": "ok"}

if __name__ == "__main__":
    print("Starting simple test server on http://0.0.0.0:8099")
    uvicorn.run(app, host="0.0.0.0", port=8099) 
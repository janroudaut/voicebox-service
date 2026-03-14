"""
Entrypoint that mounts the built web frontend onto the FastAPI app,
then starts uvicorn. This avoids patching upstream backend code.
"""

from pathlib import Path

from backend.main import app
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

FRONTEND_DIR = Path("/app/frontend")

if FRONTEND_DIR.is_dir():
    # Remove the upstream JSON root route so we can serve the web UI instead
    app.routes[:] = [r for r in app.routes if not (hasattr(r, "path") and r.path == "/" and hasattr(r, "methods") and "GET" in r.methods)]

    @app.get("/", include_in_schema=False)
    async def serve_index():
        return FileResponse(FRONTEND_DIR / "index.html")

    # Mount static assets (JS/CSS)
    app.mount("/assets", StaticFiles(directory=FRONTEND_DIR / "assets"), name="frontend-assets")

    # Catch-all for SPA client-side routing (must be last)
    @app.get("/{path:path}", include_in_schema=False)
    async def serve_spa(path: str):
        file = FRONTEND_DIR / path
        if file.is_file():
            return FileResponse(file)
        return FileResponse(FRONTEND_DIR / "index.html")

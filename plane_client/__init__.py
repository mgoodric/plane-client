"""plane_client — a dependency-free Python client, CLI, and MCP server for Plane.

See :class:`plane_client.core.PlaneClient`. The ``plane`` console command and the
``python -m plane_client.mcp_server`` MCP server are both thin frontends over it.
"""

from .core import (
    PlaneAPIError,
    PlaneClient,
    PlaneParseError,
    PlaneRateLimitError,
    RetryPolicy,
    markdown_to_html,
    resolve_ref,
    strip_control_chars,
)

__version__ = "0.1.0"

__all__ = [
    "PlaneClient",
    "RetryPolicy",
    "PlaneAPIError",
    "PlaneRateLimitError",
    "PlaneParseError",
    "resolve_ref",
    "strip_control_chars",
    "markdown_to_html",
    "__version__",
]

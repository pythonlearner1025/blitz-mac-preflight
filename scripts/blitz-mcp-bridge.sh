#!/bin/bash
# Compatibility shim for older Blitz MCP configs.
# New Codex and .mcp.json entries should launch ~/.blitz/blitz-macos-mcp directly.

HELPER="$HOME/.blitz/blitz-macos-mcp"

if [ ! -x "$HELPER" ]; then
    echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Blitz MCP helper is not installed. Start Blitz first."}}' >&2
    exit 1
fi

exec "$HELPER" "$@"

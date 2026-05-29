#!/bin/bash
# Test script for SoniqueBar infrastructure commands

echo "=== Testing SoniqueBar CommandServer ==="
echo

echo "[1] Health Check"
curl -s http://localhost:8890/health | python3 -m json.tool
echo
echo

echo "[2] Time Query (conversational)"
curl -s -X POST http://localhost:8890/command \
  -H "Content-Type: application/json" \
  -d '{"text":"what time is it?"}' | python3 -m json.tool
echo
echo

echo "[3] Restart Container (infrastructure)"
curl -s -X POST http://localhost:8890/command \
  -H "Content-Type: application/json" \
  -d '{"text":"restart n8n"}' | python3 -m json.tool
echo
echo

echo "[4] Check Docker Status (infrastructure)"
curl -s -X POST http://localhost:8890/command \
  -H "Content-Type: application/json" \
  -d '{"text":"check docker status"}' | python3 -m json.tool
echo
echo

echo "[5] Helmsman Queue (infrastructure)"
curl -s -X POST http://localhost:8890/command \
  -H "Content-Type: application/json" \
  -d '{"text":"what is in the queue?"}' | python3 -m json.tool
echo
echo

echo "=== All Tests Complete ==="

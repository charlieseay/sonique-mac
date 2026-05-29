# SoniqueBar Cleanup Instructions

## What Changed

We simplified the architecture — **no WebRTC needed**. SoniqueBar is now just a simple HTTP server that receives text commands from iOS and executes them.

---

## Steps to Clean Up Xcode

### 1. Remove WebRTC Package

1. Open `SoniqueBar.xcodeproj` in Xcode
2. Select the **SoniqueBar project** (blue icon at the top of the sidebar)
3. Select the **SoniqueBar target**
4. Click the **"Package Dependencies"** tab
5. Select **WebRTC** in the list
6. Click the **"-"** button at the bottom
7. Confirm removal

### 2. Remove WebRTC from Frameworks

1. Still on the SoniqueBar target, click the **"General"** tab
2. Scroll to **"Frameworks, Libraries, and Embedded Content"**
3. Select **WebRTC**
4. Click the **"-"** button
5. **Keep Starscream** — we'll use it on iOS later

### 3. Remove Deleted Files from Xcode

The files are already deleted from disk, but Xcode still references them:

1. In the left sidebar, expand **Services**
2. You'll see **WebRTCServer** and **TTSStreamer** in red (missing files)
3. **Right-click each** → **Delete** → **Remove Reference** (not "Move to Trash")

### 4. Add the New File

1. In the left sidebar, **right-click on Services**
2. Select **"Add Files to 'SoniqueBar'..."**
3. Navigate to: `~/Projects/sonique-mac/SoniqueBar/Services/`
4. Select **`CommandServer.swift`**
5. Make sure:
   - ✅ "Add to targets: SoniqueBar" is **checked**
   - ✅ "Create groups" is selected
6. Click **"Add"**

### 5. Build

1. Press **Cmd+B** to build
2. Should succeed with no errors

---

## What CommandServer Does

- **HTTP server** on port `8890`
- **GET /health** → returns `{"status":"ok"}`
- **POST /command** → receives `{"text":"..."}` and returns `{"response":"..."}`
- Routes commands to infrastructure (shell, MCP, Helmsman)

---

## Testing

After building successfully:

1. Run the app (Cmd+R)
2. Open Terminal
3. Test the health endpoint:
   ```bash
   curl http://localhost:8890/health
   ```
   Should return: `{"status":"ok","port":8890}`

4. Test a command:
   ```bash
   curl -X POST http://localhost:8890/command \
     -H "Content-Type: application/json" \
     -d '{"text":"what time is it?"}'
   ```
   Should return a JSON response with the current time

---

## Next Steps

Once this works:
1. Wire CommandServer to IntentRouter (conversation vs infrastructure)
2. Add Process.run() for shell commands
3. Add MCP tool invocation
4. Build iOS client with ElevenLabs streaming

---

The new architecture is **much simpler** and avoids all the WebRTC complexity.

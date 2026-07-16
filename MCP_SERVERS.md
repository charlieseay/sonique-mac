# MCP Servers for Sonique Enhancement

**Research Date:** 2026-07-16  
**Goal:** Enable Expo and App Store Connect automation via MCP

---

## Expo MCP Server

### Official Server (Expo-hosted)
- **Source:** Expo.dev official
- **URL:** https://docs.expo.dev/mcp/
- **Status:** Available on Free plan (as of 2026)
- **Changelog:** https://expo.dev/changelog/the-expo-mcp-server-is-now-available-on-the-free-plan

### Capabilities
- Expo SDK integration with AI tools (Claude Code, Cursor, VS Code)
- Mobile simulator interaction
- React Native DevTools access
- EAS build status inspection
- Workflow runs, logs, failures
- TestFlight crashes/feedback analysis
- Screenshots and flow automation (with local dev server)
- View inspection and log collection

### Community Alternatives
1. **CaullenOmdahl/expo-mcp-server**
   - GitHub: https://github.com/CaullenOmdahl/expo-mcp-server
   - Programmatic Expo.dev and EAS services interaction

2. **jaksm/expo-docs-mcp**
   - GitHub: https://github.com/jaksm/expo-docs-mcp
   - Semantic search of Expo documentation

---

## App Store Connect MCP Servers

### Recommended: pofky/appstore-connect-mcp
- **Source:** https://mcpservers.org/servers/pofky/appstore-connect-mcp
- **Status:** Maintained successor (Feb 2026+)
- **Features:**
  - 13 opinionated tools
  - 3 slash-command Prompts
  - Claude Skill included
  - Archived predecessor: JoshuaRileyDev/app-store-connect-mcp-server

### Alternative Options

1. **justthecontent/app-store-connect-mcp-server**
   - GitHub: https://github.com/justthecontent/app-store-connect-mcp-server
   - JWT authentication
   - Real-time data access
   - Developer tools integration

2. **akoskomuves/appstoreconnect-mcp**
   - Source: https://mcpservers.org/servers/akoskomuves/appstoreconnect-mcp
   - Comprehensive: pricing, subscriptions, IAPs, TestFlight, metadata, screenshots, events, reviews
   - Works with Claude Code, Claude Desktop, Cursor, Windsurf

3. **ryaker/appstore-connect-mcp**
   - GitHub: https://github.com/ryaker/appstore-connect-mcp
   - iOS-compatible OAuth
   - Comprehensive App Store Connect API integration

### Capabilities Across Servers
- App management
- Beta tester management
- Bundle ID management
- Device management
- App metadata editing
- Screenshot management
- In-app event management
- Review submission handling
- Pricing and subscription management
- TestFlight integration

---

## Installation Priority

### Phase 1: Expo MCP (Easier, Official)
1. Use official Expo-hosted server (no self-hosting needed)
2. Follow setup at https://docs.expo.dev/mcp/
3. Configure in Claude Desktop config
4. Test with Sonique iOS repo

### Phase 2: App Store Connect MCP (More Complex)
1. Choose: **pofky/appstore-connect-mcp** (maintained, feature-rich)
2. Generate App Store Connect API key (requires Apple Developer account)
3. Install server via npm/npx
4. Configure JWT authentication
5. Test with Sonique Mac/iOS TestFlight operations

---

## Integration Plan for Sonique

### Current Limitation
Sonique uses `ask_claude_bedrock` CLI (text-only, no tool calling). To use MCP servers, need:
1. Switch from CLI to direct Bedrock Messages API
2. Implement tool calling loop
3. Wire MCP servers into tool registry

### Alternative: Claude Desktop Bridge
Instead of integrating MCP into Sonique directly, route complex operations through Claude Desktop:
1. Sonique → HTTP → CommandServer → ClaudeCodeBridge → `claude` CLI (not Bedrock)
2. Claude CLI has MCP servers available
3. Simpler path, leverages existing MCP config

### Recommendation
**Phase 1:** Document MCP servers for manual use (this file)  
**Phase 2:** Test Expo/ASC servers in Claude Desktop separately  
**Phase 3:** Decide if Sonique should route through Claude Desktop CLI or stay with Bedrock

---

## Sources

### Expo MCP Research
- [Expo Docs MCP Server | LobeHub](https://lobehub.com/mcp/ah2-io-expo-docs-mcp)
- [Expo MCP Server now on Free plan - Changelog](https://expo.dev/changelog/the-expo-mcp-server-is-now-available-on-the-free-plan)
- [Using Model Context Protocol with Expo - Official Docs](https://docs.expo.dev/mcp/)
- [GitHub - CaullenOmdahl/expo-mcp-server](https://github.com/CaullenOmdahl/expo-mcp-server)
- [GitHub - jaksm/expo-docs-mcp](https://github.com/jaksm/expo-docs-mcp)

### App Store Connect MCP Research
- [GitHub - JoshuaRileyDev/app-store-connect-mcp-server](https://github.com/JoshuaRileyDev/app-store-connect-mcp-server)
- [GitHub - justthecontent/app-store-connect-mcp-server](https://github.com/justthecontent/app-store-connect-mcp-server)
- [App Store Connect MCP | Awesome MCP Servers](https://mcpservers.org/servers/akoskomuves/appstoreconnect-mcp)
- [pofky/appstore-connect-mcp | Maintained Successor](https://mcpservers.org/servers/pofky/appstore-connect-mcp)
- [GitHub - ryaker/appstore-connect-mcp](https://github.com/ryaker/appstore-connect-mcp)

---

## Next Steps

1. ✅ Research complete - documented both MCP servers
2. ⏸️ **Decision point:** Integrate MCP into Sonique or keep separate?
3. ⏸️ If integrating: Switch from `ask_claude_bedrock` to tool-calling architecture
4. ⏸️ If separate: Document MCP servers for manual use in Claude Desktop

**Recommendation:** Keep MCP servers separate for now. Sonique's simplified architecture (Option B) prioritizes personal use over feature complexity. Adding tool calling is significant work that may not align with "keep it simple" philosophy.

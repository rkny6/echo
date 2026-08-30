# Echo Architecture

This refactor keeps the current product behavior and UI contract while simplifying the application layer.

## Principles

1. **The view model owns UI state, not every domain.**
2. **Stable services stay stable.** Persistence, LLM adapters, MCP transport, HealthKit logic, diary generation, memory, and proactive scheduling remain independently testable services.
3. **Features are façades, not new business layers.** A feature groups the operations a screen needs and delegates to the existing domain service.
4. **The chat path stays narrow.** User input becomes a conversation operation; prompt/context assembly and delivery remain below the UI layer.
5. **Cross-context data uses snapshots.** SwiftData models stay behind their owners where possible.

## Application shape

```text
SwiftUI Views
    |
    v
AppViewModel
    |
    +-- ChatFeature
    +-- ProfileFeature
    +-- APIProfileFeature
    +-- SettingsFeature
    +-- DiaryFeature
    +-- MemoryFeature
    +-- DiagnosticsFeature
    +-- ProactiveFeature
    |
    v
Existing domain services / actors
    |
    +-- ChatMessageStore
    +-- ConversationManager
    +-- ProfileService
    +-- MemoryManager
    +-- DiaryService
    +-- ProactiveEngagementCoordinator
    +-- Health / Location / Notification services
    +-- LLM + MCP
```

The important design choice is **not** to create a protocol for every class. New abstractions should be introduced when they represent a real seam: persistence ownership, external I/O, a domain boundary, or a meaningful test seam.

## Migration rule

When adding a feature:

- add domain logic to a domain service/actor;
- expose only the screen-facing operations through a small feature façade;
- keep `AppViewModel` responsible for published state and app lifecycle;
- avoid adding another cross-domain dependency to `ConversationManager` unless the conversation engine truly needs it.

// Only the unrelated legacy overlay accessors in ServerScoreDisplay need this app facade.
// Context adapters use the explicit ServerScoreViewState supplied by the actual tests.
enum ServerScoringSettings { static let isEnabled = false }

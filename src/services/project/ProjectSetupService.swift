import Foundation

/// Scaffolds a new React Native / Blitz project from the bundled template.
/// Handles the full lifecycle: copy template → patch placeholders → write .dev.vars
/// The AI agent handles npm install, pod install, metro, and builds.
struct ProjectSetupService {

    enum SetupStep: String {
        case copying = "Copying template..."
        case ready = "Ready"
    }

    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let sampleDevVars = """
    JWT_SECRET_MAIN=this_is_the_main_secret_used_for_all_tables_and_admin
    JWT_SECRET_USERS=secret_used_for_users_table_appended_to_the_main_secret
    ADMIN_SERVICE_TOKEN=password_for_accessing_the_backend_as_admin
    ADMIN_JWT_SECRET=this_will_be_used_for_jwt_token_for_admin_operations
    POCKET_UI_VIEWER_PASSWORD=admin_db_password_for_readonly_mode
    POCKET_UI_EDITOR_PASSWORD=admin_db_password_for_readwrite_mode
    MAILGUN_API_KEY=api-key-from-mailgun
    API_ROUTE=NA
    """

    private static let projectNamePlaceholder = "__PROJECT_NAME__"

    /// Set up a new project from the bundled RN template.
    /// Calls `onStep` on the main actor as each phase begins.
    static func setup(
        projectId: String,
        projectName: String,
        projectPath: String,
        onStep: @MainActor (SetupStep) -> Void
    ) async throws {
        let spec = ProjectTemplateSpec(
            templateName: "rn-notes-template",
            missingTemplateMessage: "Bundled RN template not found",
            replacements: [projectNamePlaceholder: projectName],
            sampleDevVars: sampleDevVars,
            cleanupPaths: [".local-persist"],
            logPrefix: "setup"
        )
        try await ProjectTemplateScaffolder.scaffold(
            spec: spec,
            projectPath: projectPath,
            onStep: onStep
        )
    }
}

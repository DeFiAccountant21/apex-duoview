public enum F1TVError: Error, Equatable, Sendable {
    case notSignedIn
    case refused(status: Int)
    case noVideoPlan
    case network(String)
    case server(status: Int, message: String)
    case badResponse(String)
    case protectedContent
}

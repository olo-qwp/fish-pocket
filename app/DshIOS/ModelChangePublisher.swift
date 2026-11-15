import Combine
import Foundation

/// The changes a derived snapshot has to follow.
///
/// `withObservationTracking` followed whichever properties a derivation happened to read,
/// across nested models. Combine has no such read tracking: every model whose properties
/// a snapshot reads is named here once, and the snapshots (Live Activity, watch, widgets,
/// share targets) re-derive on any of them. Coarser than before, and cheap: each derivation
/// ends in an `apply` that ignores what did not change.
extension AppModel {
    static func changePublisher(_ app: AppModel) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            app.objectWillChange.eraseToAnyPublisher(),
            app.account.objectWillChange.eraseToAnyPublisher(),
            app.fishPocket.objectWillChange.eraseToAnyPublisher(),
            app.cordis.objectWillChange.eraseToAnyPublisher(),
            app.remote.objectWillChange.eraseToAnyPublisher(),
        ])
        .eraseToAnyPublisher()
    }
}

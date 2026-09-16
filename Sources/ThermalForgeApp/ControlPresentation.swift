import ThermalForgeCore

/// Menu state comes from the live control snapshot. Saved profile preferences
/// are intentionally not inputs: a remembered choice cannot arm a session.
struct ControlPresentation {
    let selectedProfileID: String?
    let ownershipDescription: String
    let monitorState: MonitorState
    let paused: Bool

    init(snapshot: BackendSnapshot, profiles: [FanProfile]) {
        let requestedProfile: String?
        if snapshot.owner != nil, case .profile(let id) = snapshot.requestedIntent {
            requestedProfile = id
        } else { requestedProfile = nil }
        let profileName = profiles.first { $0.id == (snapshot.activeProfileID ?? requestedProfile) }?.name ?? "Manual"
        paused = snapshot.controlError != nil
        if snapshot.ownerKind == .gui, !paused, snapshot.restoration != .failed {
            selectedProfileID = requestedProfile
        } else if snapshot.owner == nil, !paused, snapshot.acknowledgedControl == .apple, snapshot.restoration == .verified {
            selectedProfileID = "silent"
        } else { selectedProfileID = nil }

        var description: String
        switch snapshot.acknowledgedControl {
        case .unknown:
            if snapshot.owner != nil, snapshot.restoration == .unknown {
                description = "Applying fan control…"
            } else { description = "Fan ownership unknown" }
            monitorState = .idle
        case .apple:
            if paused { description = "Control paused · Apple fan control" }
            else if let requestedProfile, snapshot.ownerKind == .gui {
                let requestedName = profiles.first { $0.id == requestedProfile }?.name ?? requestedProfile
                description = "\(requestedName) · idle, Apple fan control"
            } else { description = "Apple fan control" }
            monitorState = .idle
        case .manualRPM(let rpm):
            description = "Backend control · \(rpm) RPM acknowledged"
            monitorState = .active(profileName: snapshot.ownerKind == .cli ? "CLI" : profileName)
        case .maximum:
            description = "Backend control · maximum acknowledged"
            monitorState = .active(profileName: snapshot.ownerKind == .cli ? "CLI" : profileName)
        }
        if snapshot.restoration == .pending { description = "Restoring Apple control…" }
        if snapshot.restoration == .failed { description = "Apple restoration unverified" }
        if snapshot.ownerKind == .cli { description += " · CLI session (observing)" }
        ownershipDescription = description
    }
}

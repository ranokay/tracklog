//
//  TracklogHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import DroppyKit
import DroppyKitHarness
import Tracklog

@main
struct TracklogHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        TracklogHostPanelActivation.installIfRequested()
        return TracklogDroplet()
    }

    @MainActor
    static func main() {
        TracklogHostPanelActivation.installIfRequested()
        if CommandLine.arguments.contains("--panel-check") {
            TracklogPanelCheck.run()
        }
        DropletHarness.run(makeDroplet(), manifestURL: manifestURL)
    }
}

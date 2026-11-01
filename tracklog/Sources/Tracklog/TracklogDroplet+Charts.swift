import DroppyKit
import Foundation
import TracklogCore

public extension TracklogDroplet {
    // MARK: - Charts

    func showCharts() async {
        await runtime?.charts?.show()
    }

    func hideCharts() {
        runtime?.charts?.hide()
    }

    func refreshCharts() async {
        await runtime?.charts?.refresh()
    }

    func selectChartSource(_ source: ChartSourceSelection) async {
        await runtime?.charts?.selectSource(source)
    }

    func selectChartPeriod(_ period: ChartPeriod) async {
        guard period != .custom else {
            openChartsSettingsPage()
            return
        }
        await runtime?.charts?.selectPeriod(period)
    }

    func selectChartType(_ type: ChartType) async {
        await runtime?.charts?.selectType(type)
    }

    func setChartCurrentConnection(_ id: Int64?) async throws {
        guard let runtime else { throw ConnectionError.unavailable }
        try await runtime.setCurrentConnection(id)
    }

    func saveChartCustomRange(start: ChartDate, end: ChartDate) async throws {
        guard let charts = runtime?.charts else { throw ConnectionError.unavailable }
        try await charts.saveCustomRange(start: start, end: end)
    }

    func openChartsSettingsPage() {
        guard let host else { return }
        guard openSettingsPage(tracklogChartsPageID, title: "Charts") else {
            host.log.notice("Opening the Charts settings page was refused")
            return
        }
    }

    func presentCharts() {
        state.setTakeoverSection(.charts)
        guard let host else { return }
        host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: tracklogHistorySurfaceID),
        )
    }

    func takeoverDidDisappear() {
        runtime?.charts?.hide()
        state.setPendingListExpanded(false)
    }
}

import ProjectScannerCore

func misuse(
    _ ledger: CoverageLedger,
    _ transaction: CoverageTransactionID
) async throws {
    try await ledger.close(transaction, as: .complete)
}

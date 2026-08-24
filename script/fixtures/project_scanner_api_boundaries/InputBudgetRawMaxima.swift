import ProjectScannerCore

func misuse() {
    _ = InputBudget(maximumInputBytes: 1, maximumRetainedBytes: 1)
}

import ProjectScannerCore

func acceptsProjectID(_ type: ProjectID.Type) {}
func acceptsProjectKeyMaterial(_ type: ProjectKeyMaterial.Type) {}
func acceptsProjectKeyLease(_ type: ProjectKeyLease.Type) {}
func acceptsSuppressionFingerprint(_ type: SuppressionFingerprint.Type) {}
func acceptsSuppressionRecord(_ type: SuppressionRecord.Type) {}
func acceptsProjectBookmark(_ type: ProjectBookmark.Type) {}
func acceptsRedactedSourceField(_ type: RedactedSourceField.Type) {}
func acceptsCoverageLedger(_ type: CoverageLedger.Type) {}
func acceptsCoverageTransactionID(_ type: CoverageTransactionID.Type) {}
func acceptsRootCapability(_ type: RootCapability.Type) {}
func acceptsSessionFinding(_ type: SessionFinding.Type) {}
func acceptsSessionStore(_ type: SessionStore.Type) {}
func acceptsScanLimits(_ type: ScanLimits.Type) {}
func acceptsProjectKeyCoordinator(_ type: ProjectKeyCoordinator.Type) {}
func acceptsProjectStateStore(_ type: ProjectStateStore.Type) {}

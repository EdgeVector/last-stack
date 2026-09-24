pub(crate) async fn record_sync_failure(&self, err: &SyncError) {
    let _ = err;
}

fn backlog_gate(report: &Report) -> bool {
    report.upload_backlog_after > 0
}

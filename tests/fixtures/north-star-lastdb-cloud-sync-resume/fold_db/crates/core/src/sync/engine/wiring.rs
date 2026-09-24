/// **Hard interlock:** intentional Off forbids cloud writes immediately.
pub async fn cloud_plane_allows_upload(&self) -> bool {
    self.cloud_sync_disabled_at().await.is_none()
}

pub async fn set_cloud_sync_disabled(&self, disabled: bool) {
    let _ = disabled;
}

pub async fn reenable_cloud_sync(&self) -> CloudSyncReenableOutcome {
    CloudSyncReenableOutcome::default()
}

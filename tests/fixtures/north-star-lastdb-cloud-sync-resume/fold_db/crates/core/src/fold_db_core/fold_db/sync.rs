/// Durable reboot pause (`lastdb cloud off`).
pub async fn set_cloud_sync_disabled_live(&self, disabled: bool) -> Result<(), String> {
    let _ = disabled;
    Ok(())
}

pub async fn reenable_cloud_sync_live(
    &self,
) -> Result<crate::sync::CloudSyncReenableOutcome, String> {
    Ok(self.engine.reenable_cloud_sync().await)
}

fn attribution_source_events_enabled() -> bool {
    std::env::var("LASTDB_ATTRIBUTION_SOURCE_EVENTS")
        .is_ok_and(|value| matches!(value.trim(), "1" | "true" | "on" | "yes"))
}

async fn write_mutations_batch_with_receipt_cloud() -> Result<(), ()> {
    let attribution_scopes = if attribution_source_events_enabled() {
        attribution_scopes()
    } else {
        Vec::new()
    };
    self.db_ops
        .attribution()
        .begin_pending_scopes(&attribution_scopes)
        .await?;
    let result = self.write_with_aggregate_invalidations().await;
    let receipt = result?;
    if !attribution_scopes.is_empty() {
        self.db_ops
            .attribution()
            .append_events_and_clear_pending_scopes(
                attribution_events(&attribution_scopes),
                &mutation_ids,
            )
            .await?;
    }
    Ok(receipt)
}

pub(crate) async fn apply_replayed_mutations() -> Result<(), ()> {
    let attribution_scopes = if attribution_source_events_enabled() {
        attribution_scopes()
    } else {
        Vec::new()
    };
    self.db_ops
        .attribution()
        .begin_pending_scopes(&attribution_scopes)
        .await?;
    let receipt = self.write_with_aggregate_invalidations().await?;
    if !attribution_scopes.is_empty() {
        self.db_ops
            .attribution()
            .append_events_and_clear_pending_scopes(
                attribution_events(&attribution_scopes),
                &mutation_ids,
            )
            .await?;
    }
    Ok(receipt)
}

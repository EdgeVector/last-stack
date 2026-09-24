//! Durable state for a schema-root attribution cutover.
//!
//! This module records the attribution protocol only. It never authorizes a
//! delete.

impl AttributionEpoch {
    pub fn complete(&mut self, final_frontier: u64) -> Result<(), String> {
        if !self.walk_complete {
            return Err("attribution object walk is incomplete".to_string());
        }
        if self.copy_snapshot_id.is_none() || self.copy_frontier != Some(final_frontier) {
            return Err(
                "attribution epoch needs an exact copy snapshot at the final frontier".to_string(),
            );
        }
        if !self.unknown_scopes.is_empty() {
            return Err("attribution epoch has unknown scopes".to_string());
        }
        Ok(())
    }

    /// This confirms a complete attribution proof. It is never a delete gate.
    pub fn has_complete_attribution_proof(&self) -> bool {
        self.unknown_scopes.is_empty() && self.copy_snapshot_id.is_some()
    }
}

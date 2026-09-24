//! Durable, fixed-size attribution rows for owner-only copy migration.
//!
//! The ledger never puts a schema list in an atom.

#[serde(rename_all = "kebab-case")]
pub enum AttributionClass {
    SchemaAttributed,
    RetentionAttributed,
    SystemAttributed,
    DerivedAttributed,
    UnattributedResidue,
    Unknown,
}

impl AttributionClass {
    fn needs_root(self) -> bool {
        matches!(
            self,
            Self::SchemaAttributed
                | Self::RetentionAttributed
                | Self::SystemAttributed
                | Self::DerivedAttributed
        )
    }
}

impl AttributionRecord {
    pub fn residue() -> Self {
        Self {
            classification: AttributionClass::UnattributedResidue,
            root_count: 0,
            path_set_digest: None,
        }
    }

    pub fn unknown() -> Self {
        Self {
            classification: AttributionClass::Unknown,
            root_count: 0,
            path_set_digest: None,
        }
    }

    pub fn validate(&self) -> Result<(), ()> {
        if self.classification.needs_root() && self.root_count == 0 {
            return Err(());
        }
        if matches!(
            self.classification,
            AttributionClass::UnattributedResidue | AttributionClass::Unknown
        ) && (self.root_count != 0 || self.path_set_digest.is_some())
        {
            return Err(());
        }
        Ok(())
    }
}

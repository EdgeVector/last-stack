//! Cloud sync v1 object model: mutation log + snapshot frontier F + CAS latest.
pub const SNAPSHOT_LOG_MODEL_VERSION: u32 = 1;

pub fn cas_allows_replace(current: Option<&Self>, candidate: &Self) -> bool {
    current != candidate
}

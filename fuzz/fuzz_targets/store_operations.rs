#![no_main]

mod common;

use std::collections::BTreeSet;

use hop_core::bundle::{Bundle, BundleId, BundleOpts};
use hop_core::store::{KvMutation, MemoryStore, Store, MAX_SEEN_ROWS};
use hop_store_sqlite::SqliteStore;
use libfuzzer_sys::fuzz_target;

const PRELOADED_BUNDLES: usize = 4;
const MAX_EXTRA_MUTATIONS: usize = 8;
const MAX_TRACKED_IDS: usize = PRELOADED_BUNDLES + 1 + MAX_EXTRA_MUTATIONS;

#[derive(Debug, PartialEq, Eq)]
struct Snapshot {
    held: Vec<(BundleId, Vec<u8>)>,
    seen: Vec<(BundleId, u64)>,
    kv: Vec<(String, Vec<u8>)>,
}

struct FaultTransactionalStore {
    committed: MemoryStore,
    fail_after: Option<usize>,
}

impl FaultTransactionalStore {
    fn apply(&mut self, mutations: &[KvMutation]) -> Result<(), String> {
        let mut candidate = self.committed.clone();
        for (index, mutation) in mutations.iter().enumerate() {
            if self.fail_after == Some(index) {
                return Err(format!("injected failure at mutation boundary {index}"));
            }
            candidate.apply_kv_batch(std::slice::from_ref(mutation))?;
        }
        if self.fail_after == Some(mutations.len()) {
            return Err(format!(
                "injected failure at mutation boundary {}",
                mutations.len()
            ));
        }
        self.committed = candidate;
        Ok(())
    }
}

fn vaccine(marker: u8, index: u8, data: &[u8]) -> Bundle {
    let mut token = [0u8; 32];
    token[0] = marker;
    token[1] = index;
    let count = data.len().min(30);
    token[2..2 + count].copy_from_slice(&data[..count]);
    Bundle::create_vaccine(
        token,
        BundleOpts {
            lifetime_ms: 60_000u32.saturating_add(u32::from(index)),
            copies: 8,
            ..Default::default()
        },
    )
}

fn snapshot(store: &impl Store, tracked_ids: &[BundleId]) -> Snapshot {
    let mut held: Vec<_> = store
        .have()
        .ids
        .into_iter()
        .map(|id| {
            let bytes = store
                .get(&id)
                .expect("have id must resolve")
                .to_bytes()
                .expect("held bundle must encode");
            (id, bytes)
        })
        .collect();
    held.sort_unstable_by_key(|(id, _)| *id);

    let unique: BTreeSet<_> = tracked_ids.iter().copied().collect();
    let seen = unique
        .into_iter()
        .filter_map(|id| store.seen_expiry(&id).map(|expiry| (id, expiry)))
        .collect();
    Snapshot {
        held,
        seen,
        kv: store.list_kv("fuzz/"),
    }
}

fuzz_target!(|input: &[u8]| {
    let bytes = common::bounded_bytes(input, 256);
    let mut initial = MemoryStore::new();
    let mut tracked_ids = Vec::with_capacity(MAX_TRACKED_IDS);
    let mut preloaded = Vec::with_capacity(PRELOADED_BUNDLES);
    for index in 0..PRELOADED_BUNDLES {
        let bundle = vaccine(0x10, index as u8, &bytes);
        tracked_ids.push(bundle.id());
        preloaded.push(bundle.id());
        assert!(initial.put(bundle, 1_000 + index as u64));
        initial.put_kv(&format!("fuzz/remove/{index}"), vec![index as u8]);
    }

    let inserted = vaccine(0x80, 0, &bytes);
    let inserted_id = inserted.id();
    tracked_ids.push(inserted_id);
    let mut batch = vec![
        KvMutation::Put {
            key: "fuzz/put/fixed".into(),
            value: bytes.clone(),
        },
        KvMutation::PutBundle {
            bundle: Box::new(inserted),
            now_ms: 2_000,
        },
        KvMutation::RemoveBundle { id: preloaded[0] },
        KvMutation::Remove {
            key: "fuzz/remove/0".into(),
        },
    ];

    for (index, operation) in bytes.chunks(4).take(MAX_EXTRA_MUTATIONS).enumerate() {
        match operation.first().copied().unwrap_or(0) % 4 {
            0 => batch.push(KvMutation::Put {
                key: format!("fuzz/extra/{index:02}"),
                value: operation.to_vec(),
            }),
            1 => batch.push(KvMutation::Remove {
                key: format!("fuzz/extra/{index:02}"),
            }),
            2 => {
                let bundle = vaccine(0xc0, index as u8, operation);
                tracked_ids.push(bundle.id());
                batch.push(KvMutation::PutBundle {
                    bundle: Box::new(bundle),
                    now_ms: 3_000 + index as u64,
                });
            }
            _ => batch.push(KvMutation::RemoveBundle {
                id: preloaded[index % preloaded.len()],
            }),
        }
    }

    let before = snapshot(&initial, &tracked_ids);
    let mut expected = initial.clone();
    expected
        .apply_kv_batch(&batch)
        .expect("generated mixed batch must be valid");
    let expected_snapshot = snapshot(&expected, &tracked_ids);

    // Exercise the production SQLite transaction, not only the in-memory semantic model. A replayed
    // bundle insertion is expected to reject the whole transaction without exposing the preceding KV
    // mutation, which catches accidental partial commits in either direction of a mixed batch.
    let mut sqlite = SqliteStore::open(":memory:").expect("in-memory SQLite must open");
    for (index, id) in preloaded.iter().enumerate() {
        assert!(sqlite.put(
            initial.get(id).expect("preloaded bundle").clone(),
            1_000 + index as u64,
        ));
        sqlite.put_kv(&format!("fuzz/remove/{index}"), vec![index as u8]);
    }
    assert_eq!(snapshot(&sqlite, &tracked_ids), before);
    sqlite
        .apply_kv_batch(&batch)
        .expect("SQLite mixed batch must commit atomically");
    assert_eq!(snapshot(&sqlite, &tracked_ids), expected_snapshot);
    let sqlite_settled = snapshot(&sqlite, &tracked_ids);
    assert!(sqlite.apply_kv_batch(&batch).is_err());
    assert_eq!(
        snapshot(&sqlite, &tracked_ids),
        sqlite_settled,
        "a rejected SQLite replay exposed a batch prefix"
    );

    for boundary in 0..=batch.len() {
        let mut transaction = FaultTransactionalStore {
            committed: initial.clone(),
            fail_after: Some(boundary),
        };
        assert!(transaction.apply(&batch).is_err());
        assert_eq!(
            snapshot(&transaction.committed, &tracked_ids),
            before,
            "failure at boundary {boundary} exposed a batch prefix"
        );

        transaction.fail_after = None;
        transaction
            .apply(&batch)
            .expect("retry after an injected failure must commit");
        assert_eq!(
            snapshot(&transaction.committed, &tracked_ids),
            expected_snapshot,
            "retry after boundary {boundary} differs from successful batch semantics"
        );

        let settled = snapshot(&transaction.committed, &tracked_ids);
        let _ = transaction.apply(&batch);
        assert_eq!(
            snapshot(&transaction.committed, &tracked_ids),
            settled,
            "reapplying a settled batch must be idempotent"
        );
    }

    assert_eq!(expected.get_kv("fuzz/put/fixed"), Some(bytes));
    assert_eq!(expected.get_kv("fuzz/remove/0"), None);
    assert!(expected.contains(&inserted_id));
    assert!(expected.seen(&inserted_id));
    assert!(!expected.contains(&preloaded[0]));
    assert!(expected.seen(&preloaded[0]));
    assert!(expected_snapshot.held.len() <= MAX_TRACKED_IDS);
    assert!(expected_snapshot.seen.len() <= MAX_TRACKED_IDS);
    assert!(expected_snapshot.seen.len() <= MAX_SEEN_ROWS);
});

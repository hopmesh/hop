//! Reconcile watermarks, persisted in BigQuery (DESIGN.md §37).
//!
//! Why BigQuery and not Firestore: the billingd service account is deliberately Firestore
//! READ-ONLY (`roles/datastore.viewer`), and `roles/bigquery.dataEditor`, already granted for the
//! usage history, covers both the jobless `tabledata.list` read and the `insertAll` streaming
//! write. So watermarks live in a tiny append-only table (`hop_usage.reconcile_watermarks`) with
//! ZERO new IAM: on startup we page the table and take the max per dimension client-side (no SQL,
//! no `bigquery.jobs.create`), and after a successful run we append one row per dimension that
//! ADVANCED.
//!
//! Crash-safety is inherited from the reconcile contract: a crash between the Stripe emits and the
//! watermark append leaves a stale watermark, which re-emits the same window onto the same
//! deterministic idempotency keys next run, and Stripe dedups. Losing a watermark row can
//! double-nothing; it only costs a retry.
//!
//! Everything except the socket is pure and unit-tested (the same discipline as `stripe.rs`): URL
//! construction, the list-response parse, the max fold, and the insert body. Only [`BqTransport`]
//! touches the network, with a `reqwest` impl under `--features live`.

use std::collections::BTreeMap;

/// The watermark dimensions, matching the reconcile entry points. String-typed in the table so a
/// future dimension is a new row, never a schema change.
pub const DIM_CARRIAGE: &str = "carriage";
pub const DIM_TELEMETRY: &str = "telemetry";

/// `tabledata.list` URL for the watermark table (jobless read, satisfied by `dataEditor`).
pub fn list_url(project: &str, dataset: &str, table: &str) -> String {
    format!(
        "https://bigquery.googleapis.com/bigquery/v2/projects/{project}/datasets/{dataset}/tables/{table}/data?maxResults=10000"
    )
}

/// `insertAll` URL for the watermark table (streaming write, satisfied by `dataEditor`).
pub fn insert_url(project: &str, dataset: &str, table: &str) -> String {
    format!(
        "https://bigquery.googleapis.com/bigquery/v2/projects/{project}/datasets/{dataset}/tables/{table}/insertAll"
    )
}

/// Fold a `tabledata.list` response page into `dimension -> max(watermark)`. BigQuery encodes every
/// cell as a string (`{"f":[{"v":"carriage"},{"v":"402"},{"v":"1752000000000"}]}` in schema field
/// order: dimension, watermark, updated_ms); a malformed row is skipped, never fatal.
pub fn fold_watermarks(page: &serde_json::Value, acc: &mut BTreeMap<String, u64>) {
    let Some(rows) = page["rows"].as_array() else {
        return;
    };
    for row in rows {
        let Some(cells) = row["f"].as_array() else {
            continue;
        };
        let (Some(dim), Some(wm)) = (
            cells.first().and_then(|c| c["v"].as_str()),
            cells.get(1).and_then(|c| c["v"].as_str()),
        ) else {
            continue;
        };
        let Ok(wm) = wm.parse::<u64>() else { continue };
        let entry = acc.entry(dim.to_string()).or_insert(0);
        *entry = (*entry).max(wm);
    }
}

/// The `insertAll` body appending one advanced watermark. `insertId` dedups the streaming insert
/// on a retry (deterministic per (dimension, watermark), the same idea as the Stripe identifier).
pub fn insert_body(dimension: &str, watermark: u64, updated_ms: u64) -> serde_json::Value {
    serde_json::json!({
        "rows": [{
            "insertId": format!("wm:{dimension}:{watermark}"),
            "json": {
                "dimension": dimension,
                "watermark": watermark.to_string(),
                "updated_ms": updated_ms.to_string(),
            }
        }]
    })
}

/// Whether an `insertAll` 200 actually succeeded: the API reports row-level problems in an
/// `insertErrors` array while still returning 200, so a bare status check under-detects.
pub fn insert_ok(status: u16, body: &serde_json::Value) -> bool {
    (200..300).contains(&status)
        && body["insertErrors"]
            .as_array()
            .map(|e| e.is_empty())
            .unwrap_or(true)
}

/// The BigQuery network seam: GET a URL, or POST a JSON body, returning `(status, body)`.
pub trait BqTransport {
    fn get(&self, url: &str) -> Result<(u16, serde_json::Value), String>;
    fn post(&self, url: &str, body: &serde_json::Value)
        -> Result<(u16, serde_json::Value), String>;
}

/// The persisted watermarks, read once at startup.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Watermarks {
    pub carriage_hour: u64,
    pub telemetry_hour: u64,
}

/// Read the watermark table and fold to the max per dimension. A missing/empty table (404 or no
/// rows) is simply "never reconciled" (all zeros): the first run starts from hour 0 and the
/// reconcilers' own window filter keeps that cheap.
pub fn read_watermarks<T: BqTransport>(
    transport: &T,
    project: &str,
    dataset: &str,
    table: &str,
) -> Result<Watermarks, String> {
    let mut acc = BTreeMap::new();
    let base = list_url(project, dataset, table);
    let mut page_token: Option<String> = None;
    loop {
        let url = match &page_token {
            Some(t) => format!("{base}&pageToken={t}"),
            None => base.clone(),
        };
        let (status, body) = transport.get(&url)?;
        if status == 404 {
            break; // table not created yet: never reconciled
        }
        if !(200..300).contains(&status) {
            return Err(format!("tabledata.list {status}"));
        }
        fold_watermarks(&body, &mut acc);
        match body["pageToken"].as_str() {
            Some(t) if !t.is_empty() => page_token = Some(t.to_string()),
            _ => break,
        }
    }
    Ok(Watermarks {
        carriage_hour: acc.get(DIM_CARRIAGE).copied().unwrap_or(0),
        telemetry_hour: acc.get(DIM_TELEMETRY).copied().unwrap_or(0),
    })
}

/// Append one advanced watermark row. Returns `Err` on transport failure, a non-2xx, or row-level
/// `insertErrors` (all of which just mean the same window retries next run).
pub fn append_watermark<T: BqTransport>(
    transport: &T,
    project: &str,
    dataset: &str,
    table: &str,
    dimension: &str,
    watermark: u64,
    updated_ms: u64,
) -> Result<(), String> {
    let url = insert_url(project, dataset, table);
    let body = insert_body(dimension, watermark, updated_ms);
    let (status, resp) = transport.post(&url, &body)?;
    if insert_ok(status, &resp) {
        Ok(())
    } else {
        Err(format!("insertAll {status}: {resp}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct FakeBq {
        gets: RefCell<Vec<(u16, serde_json::Value)>>,
        posts: RefCell<Vec<(String, serde_json::Value)>>,
        post_resp: (u16, serde_json::Value),
    }
    impl FakeBq {
        fn with_pages(pages: Vec<(u16, serde_json::Value)>) -> FakeBq {
            FakeBq {
                gets: RefCell::new(pages),
                posts: RefCell::new(Vec::new()),
                post_resp: (200, serde_json::json!({})),
            }
        }
    }
    impl BqTransport for FakeBq {
        fn get(&self, _url: &str) -> Result<(u16, serde_json::Value), String> {
            let mut gets = self.gets.borrow_mut();
            if gets.is_empty() {
                return Ok((200, serde_json::json!({})));
            }
            Ok(gets.remove(0))
        }
        fn post(
            &self,
            url: &str,
            body: &serde_json::Value,
        ) -> Result<(u16, serde_json::Value), String> {
            self.posts
                .borrow_mut()
                .push((url.to_string(), body.clone()));
            Ok(self.post_resp.clone())
        }
    }

    fn row(dim: &str, wm: &str) -> serde_json::Value {
        serde_json::json!({ "f": [ {"v": dim}, {"v": wm}, {"v": "0"} ] })
    }

    #[test]
    fn reads_the_max_watermark_per_dimension_across_pages() {
        let page1 = serde_json::json!({
            "rows": [row("carriage", "400"), row("telemetry", "398")],
            "pageToken": "t1",
        });
        let page2 = serde_json::json!({
            "rows": [row("carriage", "402"), row("carriage", "401"), {"bad": true}],
        });
        let bq = FakeBq::with_pages(vec![(200, page1), (200, page2)]);
        let wm = read_watermarks(&bq, "p", "d", "t").unwrap();
        assert_eq!(wm.carriage_hour, 402, "max across appended history");
        assert_eq!(wm.telemetry_hour, 398);
    }

    #[test]
    fn a_missing_table_means_never_reconciled() {
        let bq = FakeBq::with_pages(vec![(404, serde_json::json!({}))]);
        assert_eq!(
            read_watermarks(&bq, "p", "d", "t").unwrap(),
            Watermarks::default()
        );
    }

    #[test]
    fn a_server_error_fails_the_read() {
        let bq = FakeBq::with_pages(vec![(500, serde_json::json!({}))]);
        assert!(read_watermarks(&bq, "p", "d", "t").is_err());
    }

    #[test]
    fn append_builds_a_deterministic_insert_id() {
        let bq = FakeBq::with_pages(vec![]);
        append_watermark(&bq, "p", "d", "t", DIM_CARRIAGE, 402, 12345).unwrap();
        let posts = bq.posts.borrow();
        assert_eq!(posts.len(), 1);
        assert!(posts[0].0.ends_with("/insertAll"));
        assert_eq!(posts[0].1["rows"][0]["insertId"], "wm:carriage:402");
        assert_eq!(posts[0].1["rows"][0]["json"]["watermark"], "402");
    }

    #[test]
    fn row_level_insert_errors_fail_the_append_despite_a_200() {
        let mut bq = FakeBq::with_pages(vec![]);
        bq.post_resp = (
            200,
            serde_json::json!({ "insertErrors": [ {"index": 0, "errors": [{"reason": "invalid"}]} ] }),
        );
        assert!(append_watermark(&bq, "p", "d", "t", DIM_TELEMETRY, 5, 0).is_err());
    }
}

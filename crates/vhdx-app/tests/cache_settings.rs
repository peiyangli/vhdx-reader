use serde_json::{json, Value};
use std::path::PathBuf;
use vhdx_app::{request_context, vhdx_context_create};

#[test]
#[ignore = "requires private samples and pinned native libraries"]
fn custom_cache_budgets_unlock_read_and_invalid_budgets_preserve_volume() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").unwrap());
    let context = vhdx_context_create();
    let call = |value: Value| request_context(context, value.to_string().as_bytes());
    let opened = call(json!({"op":"open","path":root.join("bitlockervhdx.vhdx")}));
    assert_eq!(opened["ok"], true);
    let session = opened["session"].as_u64().unwrap();
    let cache = json!({"plaintext_mib":16384,"ciphertext_mib":4,"plaintext_page_kib":1024});
    let unlocked = call(json!({"op":"unlock","session":session,"partition":1,
        "mode":"password","credential_file":root.join("password.txt"),"cache":cache}));
    assert_eq!(unlocked["ok"], true);
    assert_eq!(unlocked["data"]["cache"], cache);
    let read =
        || call(json!({"op":"read","session":session,"path":"/hello.txt","offset":0,"length":100}));
    let before = read();
    assert_eq!(before["ok"], true);
    assert_eq!(before["data"]["size"], 5);
    for op in ["unlock", "unlock_saved"] {
        let mut invalid =
            json!({"op":op,"session":session,"partition":1,"cache":{"plaintext_mib":32768}});
        if op == "unlock" {
            invalid["mode"] = json!("none");
        }
        assert_eq!(call(invalid)["ok"], false);
        assert_eq!(read()["data"], before["data"]);
    }
    assert_eq!(
        call(json!({"op":"unlock","session":session,"partition":1,
        "mode":"none","cache":{"plaintext_page_kib":8192}}))["ok"],
        false
    );
    assert_eq!(read()["data"], before["data"]);
    assert_eq!(call(json!({"op":"close","session":session}))["ok"], true);
}

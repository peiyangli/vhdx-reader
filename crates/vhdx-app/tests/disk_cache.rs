use serde_json::{json, Value};
use std::{fs, path::PathBuf};
use vhdx_app::{request_context, vhdx_context_create};

#[test]
#[ignore = "requires private samples and native libraries"]
fn plaintext_disk_cache_is_shared_reused_after_unlock_and_controlled_live() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").unwrap());
    let temporary =
        std::env::temp_dir().join(format!("vhdx-disk-integration-{}", std::process::id()));
    fs::create_dir_all(&temporary).unwrap();
    let cache = temporary.join("file-cache-v1");
    let a = vhdx_context_create();
    let b = vhdx_context_create();
    let call = |context, value: Value| request_context(context, value.to_string().as_bytes());
    let config = |context, master, disk, max, days| {
        call(
            context,
            json!({"op":"disk_cache_configure","directory":cache,
        "cache_enabled":master,"enabled":disk,"max_gib":max,"retention_days":days}),
        )
    };
    assert_eq!(config(a, true, true, 128, 0)["ok"], true);
    let open = |context| {
        call(
            context,
            json!({"op":"open","path":root.join("bitlockervhdx.vhdx")}),
        )["session"]
            .as_u64()
            .unwrap()
    };
    let unlock = |context, session| {
        call(
            context,
            json!({"op":"unlock","session":session,"partition":1,
        "mode":"password","credential_file":root.join("password.txt")}),
        )
    };
    let read = |context, session| {
        call(
            context,
            json!({"op":"read","session":session,"path":"/hello.txt","offset":0,"length":100}),
        )
    };
    let sa = open(a);
    assert_eq!(unlock(a, sa)["ok"], true);
    let first = read(a, sa);
    assert_eq!(first["ok"], true);
    let status = call(a, json!({"op":"disk_cache_status"}));
    assert!(status["data"]["bytes"].as_u64().unwrap() > 0);
    let hits = status["data"]["hits"].as_u64().unwrap();
    let sb = open(b);
    let wrong = call(
        b,
        json!({"op":"unlock","session":sb,"partition":1,"mode":"password","secret":"not-the-password"}),
    );
    assert_eq!(wrong["ok"], false);
    assert_eq!(read(b, sb)["ok"], false);
    assert_eq!(unlock(b, sb)["ok"], true);
    assert_eq!(read(b, sb)["data"], first["data"]);
    let status = call(a, json!({"op":"disk_cache_status"}));
    assert!(status["data"]["hits"].as_u64().unwrap() > hits);
    assert_eq!(config(b, false, true, 128, 0)["ok"], true);
    assert_eq!(
        call(a, json!({"op":"disk_cache_status"}))["data"]["cache_enabled"],
        false
    );
    assert_eq!(read(a, sa)["data"], first["data"]);
    assert_eq!(config(a, true, false, 8, 7)["ok"], true);
    assert_eq!(read(b, sb)["data"], first["data"]);
    assert_eq!(config(a, true, true, 256, 0)["ok"], false);
    assert_eq!(read(a, sa)["ok"], true);
    assert_eq!(call(b, json!({"op":"disk_cache_clear"}))["ok"], true);
    assert_eq!(
        call(a, json!({"op":"disk_cache_status"}))["data"]["bytes"],
        0
    );
    assert_eq!(call(a, json!({"op":"dispose"}))["ok"], true);
    assert_eq!(call(b, json!({"op":"dispose"}))["ok"], true);
    // Release the process cache-directory lock before removing the test tree.
    let c = vhdx_context_create();
    assert_eq!(
        call(
            c,
            json!({"op":"disk_cache_configure","directory":temporary.join("unused"),
        "cache_enabled":true,"enabled":false,"max_gib":8,"retention_days":7})
        )["ok"],
        true
    );
    call(c, json!({"op":"dispose"}));
    fs::remove_dir_all(temporary).unwrap();
}

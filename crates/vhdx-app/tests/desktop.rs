use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{fs, path::PathBuf};
use vhdx_app::request_json;
use zeroize::Zeroizing;

fn call(value: Value) -> Value {
    let data = Zeroizing::new(value.to_string().into_bytes());
    request_json(&data)
}
#[test]
#[ignore = "requires private samples and pinned native libraries"]
fn desktop_password_unlock_filter_preview_lock_and_switch() {
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").expect("VHDX_SAMPLE_DIR"));
    let encrypted = root.join("bitlockervhdx.vhdx");
    let opened = call(json!({"op":"open","path":encrypted}));
    assert_eq!(opened["ok"], true);
    let session = opened["session"].as_u64().unwrap();
    let wrong = call(
        json!({"op":"unlock","session":session,"partition":1,"mode":"password","secret":"wrong-test-value"}),
    );
    assert_eq!(wrong["error"]["code"], "wrong_credential");
    assert!(!wrong.to_string().contains("wrong-test-value"));
    // File-based path: same route as the desktop's import-password button.
    let valid = call(
        json!({"op":"unlock","session":session,"partition":1,"mode":"password","credential_file":root.join("password.txt")}),
    );
    assert_eq!(valid["ok"], true, "password file unlock failed");
    let listing = call(
        json!({"op":"list","session":session,"path":"/","start":0,"limit":200,"show_system":false}),
    );
    let entries = listing["data"]["entries"].as_array().unwrap();
    assert!(entries.iter().any(|e| e["name"] == "hello.txt"));
    let hello = entries.iter().find(|e| e["name"] == "hello.txt").unwrap();
    assert!(hello["modified_unix_ms"].as_i64().unwrap() > 0);
    assert!(entries
        .iter()
        .all(|e| !e["name"].as_str().unwrap().starts_with('$')));
    let read =
        call(json!({"op":"read","session":session,"path":"/hello.txt","offset":0,"length":262144}));
    assert_eq!(read["ok"], true);
    let file_bytes = STANDARD
        .decode(read["data"]["bytes"].as_str().unwrap())
        .unwrap();
    assert_eq!(file_bytes.len(), 5);
    let locked = call(json!({"op":"lock","session":session}));
    assert_eq!(locked["ok"], true);
    let next = locked["session"].as_u64().unwrap();
    assert_ne!(next, session);
    assert_eq!(
        call(json!({"op":"read","session":session,"path":"/hello.txt","offset":0,"length":10}))
            ["error"]["code"],
        "stale_session"
    );
    assert_eq!(
        call(json!({"op":"read","session":next,"path":"/hello.txt","offset":0,"length":10}))
            ["error"]["code"],
        "locked"
    );
    // Typed-password path uses the shared parser without ever exposing the secret in assertions.
    let credential = vhdx_core::credentials::from_file(&root.join("password.txt"), false).unwrap();
    let vhdx_core::native::Credential::Password(secret) = credential else {
        panic!("credential type")
    };
    let mut input = json!({"op":"unlock","session":next,"partition":1,"mode":"password","secret":std::str::from_utf8(&secret).unwrap()});
    let typed = request_json(&Zeroizing::new(input.to_string().into_bytes()));
    if let Some(Value::String(value)) = input.get_mut("secret") {
        use zeroize::Zeroize;
        value.zeroize();
    }
    assert_eq!(typed["ok"], true, "typed password unlock failed");
    let key = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("BitLocker")
        })
        .unwrap();
    assert_eq!(
        call(
            json!({"op":"unlock","session":next,"partition":1,"mode":"recovery","credential_file":key})
        )["ok"],
        true
    );
    let recovered =
        call(json!({"op":"read","session":next,"path":"/hello.txt","offset":0,"length":10}));
    assert_eq!(
        STANDARD
            .decode(recovered["data"]["bytes"].as_str().unwrap())
            .unwrap(),
        file_bytes
    );
    let basic = call(json!({"op":"open","path":root.join("basicvhdx.vhdx")}));
    let id = basic["session"].as_u64().unwrap();
    assert_eq!(
        call(json!({"op":"unlock","session":id,"partition":1,"mode":"none"}))["ok"],
        true
    );
    let listed = call(json!({"op":"list","session":id,"path":"/","start":0,"limit":200}));
    assert!(listed["data"]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .any(|e| e["name"] == "can.txt"));
    assert_eq!(call(json!({"op":"close","session":id}))["ok"], true);
}

#[test]
#[ignore = "requires private samples and pinned native libraries"]
fn simultaneous_images_keep_independent_unlock_close_and_failure_state() {
    use vhdx_app::{request_context, vhdx_context_create};
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").expect("VHDX_SAMPLE_DIR"));
    let a = vhdx_context_create();
    let b = vhdx_context_create();
    let c = vhdx_context_create();
    let send = |context, value: Value| {
        request_context(context, &Zeroizing::new(value.to_string().into_bytes()))
    };
    let basic = send(a, json!({"op":"open","path":root.join("basicvhdx.vhdx")}));
    let sa = basic["session"].as_u64().unwrap();
    assert_eq!(
        send(
            a,
            json!({"op":"unlock","session":sa,"partition":1,"mode":"none"})
        )["ok"],
        true
    );
    let encrypted = send(
        b,
        json!({"op":"open","path":root.join("bitlockervhdx.vhdx")}),
    );
    let sb = encrypted["session"].as_u64().unwrap();
    assert_eq!(
        send(
            b,
            json!({"op":"unlock","session":sb,"partition":1,"mode":"password","credential_file":root.join("password.txt")})
        )["ok"],
        true
    );
    let read = |context, session, path| {
        send(
            context,
            json!({"op":"read","session":session,"path":path,"offset":0,"length":64}),
        )
    };
    assert_eq!(read(a, sa, "/can.txt")["data"]["size"], 7);
    assert_eq!(read(b, sb, "/hello.txt")["data"]["size"], 5);
    assert_eq!(
        send(
            c,
            json!({"op":"open","path":root.join("missing-test-image.vhdx")})
        )["ok"],
        false
    );
    assert_eq!(read(a, sa, "/can.txt")["ok"], true);
    assert_eq!(read(b, sb, "/hello.txt")["ok"], true);
    let lock = send(b, json!({"op":"lock","session":sb}));
    assert_eq!(read(a, sa, "/can.txt")["ok"], true);
    assert_eq!(read(b, sb, "/hello.txt")["error"]["code"], "stale_session");
    assert_eq!(
        send(
            b,
            json!({"op":"unlock","session":lock["session"],"partition":1,"mode":"password","credential_file":root.join("password.txt")})
        )["ok"],
        true
    );
    assert_eq!(send(a, json!({"op":"close","session":sa}))["ok"], true);
    assert_eq!(send(a, json!({"op":"dispose"}))["ok"], true);
    assert_eq!(
        read(b, lock["session"].as_u64().unwrap(), "/hello.txt")["ok"],
        true
    );
    assert_eq!(send(b, json!({"op":"dispose"}))["ok"], true);
    assert_eq!(send(c, json!({"op":"dispose"}))["ok"], true);
}

#[test]
#[ignore = "requires private samples and pinned native libraries"]
fn preview_file_handles_are_invalidated_on_reunlock_and_close() {
    use vhdx_app::{request_context, vhdx_context_create};
    let root = PathBuf::from(std::env::var_os("VHDX_SAMPLE_DIR").expect("VHDX_SAMPLE_DIR"));
    let context = vhdx_context_create();
    let send =
        |value: Value| request_context(context, &Zeroizing::new(value.to_string().into_bytes()));
    let opened = send(json!({"op":"open","path":root.join("basicvhdx.vhdx")}));
    let session = opened["session"].as_u64().unwrap();
    assert_eq!(
        send(json!({"op":"unlock","session":session,"partition":1,"mode":"none"}))["ok"],
        true
    );
    let file = send(json!({"op":"file_open","session":session,"path":"/can.txt"}));
    assert_eq!(file["data"]["size"], 7);
    let id = file["data"]["file"].as_u64().unwrap();
    let read =
        |file| send(json!({"op":"file_read","session":session,"file":file,"offset":2,"length":32}));
    assert_eq!(
        STANDARD
            .decode(read(id)["data"]["bytes"].as_str().unwrap())
            .unwrap()
            .len(),
        5
    );
    assert_eq!(
        send(json!({"op":"unlock","session":session,"partition":1,"mode":"none"}))["ok"],
        true
    );
    assert_eq!(read(id)["error"]["code"], "locked");
    let next = send(json!({"op":"file_open","session":session,"path":"/can.txt"}))["data"]["file"]
        .as_u64()
        .unwrap();
    assert_ne!(id, next);
    assert_eq!(
        send(json!({"op":"file_close","session":session,"file":id}))["ok"],
        true
    );
    assert_eq!(read(next)["ok"], true);
    assert_eq!(send(json!({"op":"close","session":session}))["ok"], true);
    assert_eq!(read(next)["error"]["code"], "stale_session");
    assert_eq!(send(json!({"op":"dispose"}))["ok"], true);
}

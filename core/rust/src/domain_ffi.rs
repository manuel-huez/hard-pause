use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::domains::{self, DomainListFormat, PortableDomainList};
use crate::HpCoreBuffer;

pub const HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT: u32 = 1;
pub const HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT: u32 = 2;

/// Opaque, read-only after creation. The same handle may serve concurrent lookups.
pub struct HpDomainIndex {
    list: PortableDomainList,
}

/// Parse a bounded domain list once and return a retained index.
/// 0 = success, -1 = invalid argument, -2 = invalid list, -3 = internal failure.
///
/// # Safety
/// Each non-null input pointer must reference its stated readable length.
/// `out_index` must be writable. The caller owns the returned handle and must
/// release it once with `hp_domain_index_free` after all lookups finish.
#[no_mangle]
pub unsafe extern "C" fn hp_domain_index_create(
    data: *const u8,
    data_len: usize,
    format: u32,
    minimum_count: usize,
    category: *const u8,
    category_len: usize,
    out_index: *mut *mut HpDomainIndex,
) -> i32 {
    if out_index.is_null() {
        return -1;
    }
    unsafe { *out_index = std::ptr::null_mut() };
    let maximum_bytes = match format {
        HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT => domains::MAXIMUM_BYTES,
        HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT => domains::MAXIMUM_SUPPLEMENT_BYTES,
        _ => return -1,
    };
    if data.is_null()
        || data_len > maximum_bytes
        || category_len > 256
        || (format == HP_DOMAIN_FORMAT_HARD_PAUSE_SUPPLEMENT
            && (category.is_null() || category_len == 0))
        || (format == HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT && category_len != 0)
    {
        return -1;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let list_data = unsafe { std::slice::from_raw_parts(data, data_len) };
        let list_format = if format == HP_DOMAIN_FORMAT_BLOCK_LIST_PROJECT {
            DomainListFormat::BlockListProject { minimum_count }
        } else {
            let category_bytes = unsafe { std::slice::from_raw_parts(category, category_len) };
            let category = std::str::from_utf8(category_bytes).map_err(|_| -1)?;
            DomainListFormat::HardPauseSupplement {
                category: category.to_owned(),
            }
        };
        PortableDomainList::parse(list_data, &list_format)
            .map(|list| Box::into_raw(Box::new(HpDomainIndex { list })))
            .map_err(|_| -2)
    }));
    match result {
        Ok(Ok(index)) => {
            unsafe { *out_index = index };
            0
        }
        Ok(Err(code)) => code,
        Err(_) => -3,
    }
}

/// Query a retained index without serializing or reparsing its domain set.
/// 0 = success, -1 = invalid argument, -3 = internal failure.
///
/// # Safety
/// `index` must be a live handle returned by `hp_domain_index_create`.
/// `host` must reference `host_len` readable bytes when non-null, and
/// `out_contains` must be writable. Do not free a handle during a lookup.
#[no_mangle]
pub unsafe extern "C" fn hp_domain_index_contains(
    index: *const HpDomainIndex,
    host: *const u8,
    host_len: usize,
    out_contains: *mut u8,
) -> i32 {
    if out_contains.is_null() {
        return -1;
    }
    unsafe { *out_contains = 0 };
    if index.is_null() || host_len > 1024 || (host.is_null() && host_len != 0) {
        return -1;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        if host_len == 0 {
            return Ok(false);
        }
        let bytes = unsafe { std::slice::from_raw_parts(host, host_len) };
        if !bytes.is_ascii() {
            return Err(-1);
        }
        let host = std::str::from_utf8(bytes).map_err(|_| -1)?;
        Ok(unsafe { &*index }.list.contains(host))
    }));
    match result {
        Ok(Ok(contains)) => {
            unsafe { *out_contains = u8::from(contains) };
            0
        }
        Ok(Err(code)) => code,
        Err(_) => -3,
    }
}

/// Serialize metadata and domains from a retained index without parsing again.
/// The caller frees the returned buffer with `hp_core_free`.
///
/// # Safety
/// `index` must be a live handle and `out` must be writable. Do not free the
/// handle during export.
#[no_mangle]
pub unsafe extern "C" fn hp_domain_index_export(
    index: *const HpDomainIndex,
    out: *mut HpCoreBuffer,
) -> i32 {
    if index.is_null() || out.is_null() {
        return -1;
    }
    unsafe {
        *out = HpCoreBuffer {
            ptr: std::ptr::null_mut(),
            len: 0,
        };
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_vec(&unsafe { &*index }.list)
    }));
    let Ok(Ok(bytes)) = result else { return -3 };
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed).cast::<u8>();
    unsafe { *out = HpCoreBuffer { ptr, len } };
    0
}

/// # Safety
/// `index` must be null or a live handle returned by `hp_domain_index_create`.
/// Release each handle only once and only after concurrent lookups finish.
#[no_mangle]
pub unsafe extern "C" fn hp_domain_index_free(index: *mut HpDomainIndex) {
    if !index.is_null() {
        unsafe { drop(Box::from_raw(index)) };
    }
}

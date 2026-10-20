<*
 A secret value returned by `read`.

 The bytes belong to the operation's arena: they stay valid while the
 `Operation` is retained. Call `wipe` when the value is no longer needed. The
 arena also zeroes its pages when it is freed, through `bleu::secrets::wipe`.

 Limits: copies made by the caller (a `String` built from the bytes, the caller's
 own buffer for `store`) are not zeroed by this library, and the bytes can
 still reach the swap file while they are in memory.
*>
module bleu::secrets;

<* Overwrite the bytes with zeros. Volatile, so the stores are not optimised away. *>
fn void Secret.wipe(&self)
{
	if (self.bytes.len == 0) return;
	mem::set(self.bytes.ptr, 0, self.bytes.len, 0, true);
}

<* The number of bytes in the secret. *>
fn sz Secret.len(&self) @inline => self.bytes.len;

# Request to Atrium PA: `delete_capture` over MCP

A prompt to hand to whoever works on `atrium-pa`. It is written to be
pasted whole; the reasoning is included because the shape of the answer
depends on it.

---

## The prompt

> Add a `delete_capture` tool to the MCP surface, so a client that
> uploaded a recording can also remove it.
>
> **Why this does not already work.** Deletion exists as
> `DELETE /pa/captures/{capture_id}` in `captures_api.py`, and it is the
> right implementation — a soft delete that flips `status` to `deleted`,
> sets `deleted_at`, writes a `CAPTURE_DELETED` audit row carrying
> `prior_status`, deliberately does *not* release the dedup index so
> source pollers don't respawn the row, and leaves
> `pa.capture_purge` to hard-delete past `PA_CAPTURE_DELETE_GRACE_DAYS`
> (default 90). There is an inverse, `POST /pa/captures/{id}/restore`.
>
> The problem is only the gate. That route depends on
> `require_pa_write_user`, which `bootstrap.init_app` overrides with
> `require_perm("pa.write")` — atrium's RBAC chain: session cookie plus
> the TOTP gate, or a PAT with intersecting scopes. An MCP client
> holding an OAuth bearer cannot satisfy it, and there is no MCP tool
> that reaches the same code. So a client can create captures
> (`upload_audio`, scope `pa.ingest`) and can never remove one. Whatever
> uploads a mistake has to ask a human with a browser to clean it up.
>
> **What I am asking for**, in order of preference:
>
> 1. A `delete_capture` MCP tool that calls the same soft-delete path,
>    gated on a scope an ingesting client can hold.
> 2. If that is the wrong scope boundary, then say so and I will keep
>    sending people to the web UI — but please make that a decision
>    rather than an omission.
>
> ### Shape
>
> Following `delete_digest`, which is the closest existing tool:
>
> ```
> delete_capture(capture_id: int, reason: str | None = None,
>                deleted: bool = true)
>   → {capture_id, status, deleted_at, transcript_id?, already_deleted}
> ```
>
> Three things I would argue for specifically:
>
> * **`deleted` as a required-ish boolean rather than a bare verb**,
>   exactly as `dismiss_speaker(voice_cluster_id, dismissed)` does it.
>   The restore path already exists server-side; exposing delete without
>   it would make the tool a one-way door, and `dismiss_speaker`'s own
>   docstring is the argument for why that is worth avoiding. If you
>   would rather have `restore_capture` as a separate tool, that is fine
>   too — what matters is that undo is reachable from MCP, not only from
>   the browser.
> * **Idempotent, returning `already_deleted`**, matching the REST
>   route's own contract. A client retrying after a dropped connection
>   should not get a 404 for work that succeeded.
> * **Say what it does not do.** The description should state plainly
>   that this is a soft delete with a grace window, that the audio in the
>   vault goes when the purge job runs rather than immediately, and that
>   the dedup index is intentionally retained — otherwise a caller will
>   assume "deleted" means "gone" and be wrong about both the audio and a
>   re-ingest.
>
> ### Scope
>
> This is the part I do not want to decide unilaterally, so here is the
> case as I see it.
>
> `pa.ingest` is described in `oauth_api.py` as "a narrow capability
> (accept audio, report its pipeline stage) with no read power of its
> own". Deleting *your own* capture is arguably the other half of being
> allowed to create one, and a client that can fill the vault but never
> empty it is an odd shape. Against that: delete is destructive in a way
> upload is not, and bundling it into `pa.ingest` silently widens what
> every existing `pa.ingest` token can do — including tokens already
> issued, which cannot be re-consented.
>
> That last point seems decisive to me, so my suggestion is a **new
> `pa.ingest:delete` scope**, added to `DEFAULT_SCOPES` and to
> `DISCOVERABLE_SCOPES`. Existing tokens are unaffected and gain nothing;
> a client that wants deletion asks for it and the operator sees it on
> the consent screen. It also leaves room to refuse it to a client you do
> not want deleting things.
>
> Note the practical consequence either way: `allowed_scopes` is pinned
> at registration (RFC 7591 §2) and refresh cannot widen (RFC 6749 §6),
> so every existing client has to re-register to pick this up. Worth
> mentioning in the release note, because "I signed in again and it still
> says FORBIDDEN" is the confusing version of that.
>
> ### Ownership
>
> `_load_owned_capture` already scopes by `owner_user_id` and 404s across
> owners. The MCP path should resolve the owner from
> `claims.client.owner_user_id` the same way `upload_audio` does, so a
> client can only delete captures belonging to the user it was minted
> for. No new ownership logic — please reuse that helper rather than
> writing a second one.
>
> ### Tests I would want to see
>
> * Deleting a capture the client does not own returns `NOT_FOUND`, not
>   `FORBIDDEN` — the same non-disclosure the REST route already gives.
> * Deleting twice returns 200 with `already_deleted: true`.
> * `deleted: false` restores, and the capture reappears in
>   `list_transcripts` / `get_upload_status`.
> * A token without the scope gets `FORBIDDEN` naming the scope, since
>   that is what a client turns into "sign in again".
> * The dedup index still refuses a re-upload of identical bytes after a
>   delete — i.e. the soft delete did not quietly become a way to
>   re-transcribe the same audio twice.
>
> ### Why I am asking rather than sending a PR
>
> `atrium-mac` is deliberately a zero-change client of this API: its
> whole contract is "use what ingest already exposes". Adding a REST
> endpoint or an MCP tool from that side was considered and rejected
> when the upload lane was built, on the grounds that a single personal
> client is not worth permanent added attack surface. That reasoning
> still holds — which is exactly why this is a request with a rationale
> attached rather than a diff.

---

## Outcome — shipped, with four corrections

`delete_capture(capture_id, deleted, reason?)` is live, built to the
shape argued for above: `deleted` required with no default, idempotent,
reporting `already_deleted` and `changed` so a retry after a dropped
connection is a legible no-op. Scope is `pa.ingest:delete`.

Four things came back that this request got wrong or missed, all now
reflected in `MCPClient.deleteCapture` and in the delete dialog:

1. **The scope is in `DEFAULT_SCOPES` but deliberately not in
   `DISCOVERABLE_SCOPES`.** A DCR client that registers with no `scope`
   field inherits the discoverable set wholesale — so advertising
   deletion there would hand it to every browser client that
   re-registers on reconnect, which is the same silent widening the
   separate-scope argument exists to prevent, arriving by another door.
   atrium-mac already sends `scope` explicitly at registration, so this
   costs nothing here; it is load-bearing rather than incidental.
2. **The audio is not deleted.** This request assumed the purge job
   removes vault blobs. It does not — it hard-deletes the capture row and
   lets the FK cascade take the projections, while blobs are unlinked by
   a separate cron on file age regardless of whether anything was
   deleted. The wording proposed above would have shipped exactly the
   "caller assumes deleted means gone" failure it was trying to prevent.
3. **Re-uploading the same file after a delete fails opaquely.** The
   duplicate check filters out soft-deleted rows, so the re-upload is not
   recognised as a duplicate, proceeds, and collides with the retained
   dedup key — an internal error with a trace id, for the whole grace
   window. Test 5 passes, but the refusal is not one a client can act on.
   This is the concrete argument for insisting undo ship in the same
   tool.
4. **The ownership note was half right.** `_load_owned_capture` scopes by
   owner and nothing else, so a tool built naively on it would have
   reached the operator's email, calendar, Slack and Plaud captures by
   integer enumeration from a token holding no read scope. The shipped
   tool restricts to `kind='transcript', provider='mcp_upload'`.
   (Also: the claim comes from `claims.sub`, not
   `claims.client.owner_user_id` — `MCPClaims` has no `client`.)

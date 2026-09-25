# Jev for Movable Type

A proof of concept for searching entries, pages, and content data in the Movable Type 9 admin interface using natural language. OpenAI embeddings narrow down the candidates, then Jev or OpenAI evaluates how well each candidate matches the conditions and ranks it by relevance. No dedicated vector database is required: vectors are stored in the MT database and compared in Perl.

## Installation

1. Copy `plugins/Jev` into MT's `plugins/` directory.
2. Copy `mt-static/plugins/Jev` into MT's `mt-static/plugins/` directory.
3. Copy `tools/Jev` into MT's `tools/` directory.
4. If you use PSGI or FastCGI, restart MT, then run the database upgrade from the admin interface. This creates the `jev_embedding` table without making any API calls.
5. Save your OpenAI API key in the system-level plugin settings and select an evaluation provider. If you use the default provider, Jev, also save your TypeSafe API key.
6. Run the following commands from the MT root directory to generate the search index for existing content.

```sh
perl tools/Jev/build-index
# Limit indexing to a site or content type
perl tools/Jev/build-index --blog-id 1 --type entry
# Regenerate embeddings even for unchanged, successfully indexed content
perl tools/Jev/build-index --blog-id 1 --force
```

`--type` accepts `entry`, `page`, or `content_data`. Omitting it indexes all three types; omitting `--blog-id` indexes all sites. A TypeSafe key is not required for indexing. The OpenAI key is read from MT's settings rather than passed as a command-line argument.

The CLI generates embeddings synchronously, one document at a time. On failure, it prints the affected ID and stops. Rerunning it skips successfully indexed documents whose content has not changed. There are no admin screens for starting, monitoring, or resuming indexing. Documents are sent to OpenAI, and API usage is billed.

Embeddings are also updated synchronously when content is created or edited. Unchanged document text is not re-embedded. Documents with failed embedding generation, no configured key, or an outdated index are excluded from natural-language search. Rerun the CLI after changing referenced names or field definitions, or after updating content directly through SQL or similar means.

The plugin requires the Perl modules `LWP::UserAgent`, `LWP::Protocol::https`, `HTTP::Request`, `JSON::PP`, `HTML::Parser`, `Digest::SHA`, and `Encode`, plus outbound HTTPS access from the MT server to `https://api.openai.com` and `https://api.typesafe.ai`. No MT core files are modified.

## Building

Like AI-Assistant, this plugin uses `ExtUtils::MakeMaker` and the Docker Compose `builder` service to create distribution archives. Run the following from the repository root with Docker and Compose available:

```sh
docker compose run --rm --build builder
```

The builder reads `version` from `plugins/Jev/config.yaml` and creates `Jev-0.2.3.tar.gz` and `Jev-0.2.3.zip` in the repository root. Running it again with the same version rebuilds the archives. After extracting an archive, copy `plugins/Jev`, `mt-static/plugins/Jev`, and `tools/Jev/build-index` to their corresponding locations in MT. The archives contain runtime files and the README, but exclude tests, specifications, blog drafts, and build files.

The builder uses UID and GID `1000` by default. To match the generated files' ownership to your current user on Linux or similar systems, run:

```sh
JEV_BUILD_UID="$(id -u)" JEV_BUILD_GID="$(id -g)" docker compose run --rm --build builder
```

To build without Docker, install Perl with `ExtUtils::MakeMaker` and `YAML`, Node.js 22, `make`, `tar`, `gzip`, and `zip`, then run the following. `make build` checks the syntax of the JavaScript files included in the distribution. No JavaScript or CSS transformation or npm package installation is needed.

```sh
perl Makefile.PL
make build
rm -f MANIFEST
make manifest
make dist
make zipdist
```

To release a new version, update `version` in `config.yaml`. As with AI-Assistant, you can override only the archive version with `perl Makefile.PL --version 0.2.3-dev`; this does not change the version displayed by the plugin.

## CI and GitHub Releases

The [build workflow](.github/workflows/build.yml) runs on branch pushes, pull requests, and tags starting with `v`. It uses the same Docker Compose builder as local builds and uploads the ZIP and tar.gz archives as a workflow artifact. Branch and pull request builds append the short commit SHA to the package and plugin version, such as `0.2.3-abc1234`.

Like AI-Assistant, tag builds use [softprops/action-gh-release](https://github.com/softprops/action-gh-release) to create a **draft GitHub Release** with both archives attached. The tag must match `version` in `plugins/Jev/config.yaml`, prefixed with `v`; a mismatch fails the build. Tagged builds keep the configured plugin version unchanged. Only the release job receives `contents: write` permission, using the automatically provided GitHub token.

To prepare a release, update the plugin version, commit and push the changes together with the workflow, then push the matching tag. For version `0.2.3`:

```sh
git tag v0.2.3
git push origin v0.2.3
```

Once the workflow succeeds, review and publish the draft on GitHub's Releases page.

## Usage

On the Search & Replace screen, enter conditions such as "Explains the installation procedure but does not mention pricing" and enable **Search with natural language**. Standard search scope restrictions, including site and child sites, date range, and publication status, still apply.

The same **Search with natural language** checkbox appears directly below the header search field. When enabled, submitting the form performs a natural-language search. It is on by default and can be changed in the settings. Types other than entries, pages, and content data use regular search. The header default does not override an explicitly unchecked checkbox or apply when the search screen is opened directly.

Natural-language search disables case sensitivity, regular expressions, field selection, and replacement. Turn it off and search again to return to regular search and replace.

1. Within the scope the user is allowed to search, collect embeddings that match the current document content.
2. Embed the search conditions with OpenAI and select the most similar candidates, 50 by default.
3. The configured provider, Jev or OpenAI, reads all searchable fields of each candidate and evaluates the conditions, including negation. By default, requests contain five documents each, with up to five requests sent concurrently. Concurrency is configurable.
4. Display candidates whose match probability meets the threshold, ordered by relevance descending, then embedding similarity descending and ID ascending to break ties. Jev uses Noul and Score; OpenAI uses generated match probability and relevance values. The display limit is applied after sorting.

Search is limited to the selected candidates, so even conditions such as "does not mention" do not guarantee complete coverage. The plugin does not evaluate all documents or fetch additional candidates when too few match. Searching again or changing the display limit makes new API calls.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Evaluation provider | `Jev` | `Jev` or `OpenAI`. Embeddings always use OpenAI. |
| OpenAI API key | Empty | Used for embedding generation and, when OpenAI is selected, evaluation. |
| TypeSafe API key | Empty | Used for Jev's condition matching and relevance scoring. |
| Jev model | `jev-latest` | Model name used when Jev is selected. |
| OpenAI evaluation model | `gpt-5.4-mini` | Model name used when OpenAI is selected. Requires Responses API and Structured Outputs support. |
| Candidate limit | `50` | 1–500. Total number of documents evaluated per search. |
| Match threshold | `0.5` | 0–1. Candidates match when the selected provider's match probability is at least this value. |
| Candidates per request | `5` | 1–50. Documents grouped into one request. Large inputs are split into smaller groups. |
| Concurrent evaluation requests | `5` | 1–10. Maximum concurrent requests per search. Set to 1 for sequential execution. |
| Log search token usage | `OFF` | Write one MT activity log entry per completed natural-language search. |
| Use natural-language search by default in header search | `ON` | Initial state of the header checkbox. |

Only the last four characters of each saved key are displayed. Saving without selecting **Update API key** preserves the existing value. Selecting it and saving an empty field deletes the key. Keys are stored in MT's standard plugin settings.

With **Log search token usage** enabled, `MT->log` records an INFO entry with category `jev_usage` and a message beginning `Jev search token usage:` followed by JSON. The entry includes the search object type, providers and model names, successful request counts, and token totals for query embedding and candidate evaluation separately. Usage from all parallel workers and size-split requests is combined into one entry. `cached_input_tokens` is included in `input_tokens`, not added to it. Counts missing from an API response are `null`, not zero; a search making no API calls records zero usage.

Logs contain no search text, document content, or API keys. They are associated with the search site (or the system scope) and the searching user. Only completed searches are logged, including searches with no matches. Failed searches, failed HTTP attempts, and embeddings generated while indexing or saving documents are excluded, so these logs are usage diagnostics rather than a complete billing ledger.

Switching the evaluation provider or evaluation model does not require rebuilding the index. OpenAI's match probability is an estimate generated by the model as JSON; it is not guaranteed to have the same probability characteristics or relevance score distribution as Jev's Noul and Score. Check thresholds and search results with the model you use. The default model is [GPT-5.4 Mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini), using [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs) for responses.

For `gpt-5.4-mini` and its dated snapshots, evaluation requests explicitly use `temperature: 0` and `reasoning.effort: none` to reduce sampling variation. These values are fixed in the plugin and do not guarantee identical results across repeated searches. Other model names retain their API defaults; sampling parameters are omitted to avoid sending unsupported settings. See the parameter compatibility section of the [GPT-5.4 guide](https://developers.openai.com/api/docs/guides/gpt-5.4).

Embeddings are fixed to `text-embedding-3-large` with 3072 dimensions. Changing the model, dimensionality, or document representation requires rebuilding the index. The raw vectors for 10,000 documents occupy approximately 123 MB, excluding database overhead and Perl memory usage.

## Data sent and limitations

Documents include all fields covered by MT's search, with HTML converted to text. Oversized embedding inputs can be shortened as described below; candidate evaluation still uses the full fields. Content is not summarized or split into chunks. Image alt text is included, but file contents, linked pages, the body of referenced objects, and fields outside MT's search scope are not read.

For content data, choice fields include both stored values and display labels, while categories and tags in the same site include IDs and names. References to assets or other content data contribute only IDs to the shared embeddings. Display names of referenced objects that the user is allowed to search are added only when sending candidates to the selected evaluation provider. Documents relevant solely because of a referenced object's display name are not guaranteed to be retrieved by the embedding stage.

- Initial indexing and saves send documents to OpenAI. Search conditions are also embedded through OpenAI. Condition matching and relevance scoring send the search conditions and top candidates to the selected provider, TypeSafe or OpenAI. There is no automatic fallback to another evaluation provider.
- With Jev selected, the overall search timeout is 45 seconds and the evaluation HTTP timeout is 10 seconds. With OpenAI selected, these limits are 180 and 60 seconds respectively. Embedding generation remains synchronous with a 10-second HTTP timeout.
- OpenAI embedding generation accepts up to 8192 tokens per input. When indexing or saving a document, a recognized HTTP 400 context-length error triggers a shorter retry, up to three times within the existing 10-second deadline. When the API reports the input token count, it determines an approximate character reduction with headroom. If the error reports only the context limit, the text is approximately halved on each retry. No tokenizer dependency is added. The longest field values are trimmed from the end first, preserving titles and content-data labels until other values are exhausted. Structured values remain valid JSON. Other API errors are not retried, and search queries are never silently shortened. If the retry limit is reached, or the error cannot be recognized, indexing still stops.
- Truncation affects only the embedding request. Original documents, full-document freshness hashes, and fields sent for condition matching remain intact. Topics mentioned only in the discarded text may be missed during candidate selection. Existing successful indexes remain valid; rerun `tools/Jev/build-index` without `--force` to skip them and retry missing indexes. The CLI writes UTF-8 diagnostics, and recognized length errors report only the input/limit token counts, never the upstream response body.
- Evaluation request JSON is limited to 24,000 bytes per candidate and 48,000 bytes per request. Condition matching and relevance scoring share the same document data. OpenAI uses Structured Outputs through the Responses API, with a maximum of 8192 output tokens. Automatic input truncation and response storage are disabled.
- Both evaluation providers use the existing LWP client, running in parallel through Perl's built-in `fork`, with up to five processes by default. No additional CPAN dependencies are required; the target environment must support `fork`, as Linux does. Concurrency is configurable from 1 to 10, and the actual number of child processes is capped by the number of candidate batches. No child process is created when concurrency is 1 or there is only one batch. HTTPS connections are reused within each process. Simultaneous searches each use their own set of processes; concurrency is not coordinated across searches.
- Document grouping, questions, batch sizes, and token counts are the same as for sequential execution. Parallelism does not increase the normal number of API calls.
- Each process retries Jev's 429 / 529 responses and OpenAI evaluation's 429 / 5xx responses up to twice. On errors or timeout, remaining child processes are terminated and reaped, and no partial results are returned. Interrupted or refused OpenAI generations, missing answers, and duplicate answers also cause search errors. Embedding generation stops on failure after any permitted shortening retries.
- API errors, oversized inputs, and timeouts cause the search to fail. Documents with missing or outdated embeddings are excluded from search.

As a proof of concept, the plugin does not provide indexing job management, automatic recovery, status aggregation, locking, or search result caching. Saves wait for API requests, which can also slow down bulk imports.

## Tests

Run tests in an environment with MT9's test dependencies installed. Regular tests mock the APIs and use a temporary SQLite database.

```sh
MT_HOME=/path/to/movabletype MT_TEST_BACKEND=SQLite prove plugins/Jev/t/*.t
MT_HOME=/path/to/movabletype MT_TEST_BACKEND=SQLite MT_TEST_ADMIN_THEME_ID=admin2023 prove plugins/Jev/t/*.t
NODE_PATH=/path/to/movabletype/node_modules node --test plugins/Jev/t/*.test.cjs
```

The optional 10,000-document benchmark exercises MT, the database, content hash comparisons, vector calculations, and result rendering, mocking only the external APIs.

```sh
MT_HOME=/path/to/movabletype MT_TEST_BACKEND=SQLite JEV_BENCHMARK=1 prove -v plugins/Jev/xt/benchmark.t
```

For a small live API check, set `OPENAI_API_KEY` and `TYPESAFE_API_KEY` as environment variables and run the following. The check uses fictional documents, makes four OpenAI calls and five Jev calls, and checks token usage, elapsed time, and the evaluation of negative conditions. It is skipped when the keys are unavailable.

```sh
prove -v plugins/Jev/xt/live.t
```

To check only OpenAI evaluation against the live API, set `OPENAI_API_KEY` and run the following. It uses three fictional documents to check negation, absence conditions, and parallel evaluation, making three Responses API calls. Set `OPENAI_EVALUATION_MODEL` to use a different model.

```sh
prove -v plugins/Jev/xt/openai-evaluation-live.t
```

## Design and verification records

[Search performance measurements and optimizations](specs/search-performance-2026-09-23.md) are also documented. Optimizations cover numeric processing of stored vectors and HTTPS connection reuse; existing indexes can be used as-is.

See the [implementation plan](specs/natural-language-search-implementation-plan.md) and [verification records](specs/natural-language-search-verification.md). `mt:JevEntries` is on hold.

The plugin modifies admin screens and wraps functions in `MT::CMS::Search`, so check both admin themes after updating MT. API contracts follow [OpenAI Embeddings](https://developers.openai.com/api/reference/resources/embeddings/methods/create), the [TypeSafe API](https://docs.typesafe.ai/api), [Noul](https://docs.typesafe.ai/primitives/noul), and [Score](https://docs.typesafe.ai/primitives/score).

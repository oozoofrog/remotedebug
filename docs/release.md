# Release procedure

A task reaches completion when all its changes are on remote `main` and each affected release destination serves the intended revision. Record the release scope, source commit, and destination checks in the task.

## 1. Identify release destinations

| Change | Release destination | Completion evidence |
| --- | --- | --- |
| Mac app or its bundled MCP server | The repository's GitHub Releases | A published release URL, tag and source commit, matching zip digests, and a successful check of the downloaded app |
| RemoteDebug iPhone app or RD updater | The agreed device distribution channel. Use the [existing iPhone update procedure](setup.md#iphone-앱-업데이트) for tailnet distribution. | The published version and build or the installed build for an agreed direct install, plus a physical-device check of the changed behavior |
| Source, documentation, or Swift package | The declared remote branch or version tag | The expected files or package revision resolve from the declared remote ref |

For changes that affect more than one destination, record each one. Record why a destination is unaffected when the scope may be unclear.

## 2. Land the change

1. Run the relevant tests and build checks. Record what ran and the results.
2. Merge all in-scope changes into `main` using the repository's merge process. If the history is squashed, record the commit created by the merge.
3. Before selecting an app release commit, confirm that `main` contains the release version and a new build number. Write the release notes for that build.
4. Push the landed `main` to `origin` if the merge process has left it local.
5. Fetch remote `main` and confirm that it contains the landing commit. Use the result to select the release revision.

```sh
git fetch origin refs/heads/main
git merge-base --is-ancestor "$landing_sha" FETCH_HEAD
git rev-parse FETCH_HEAD
```

Build from a clean checkout at the selected commit. The selected commit must be reachable from remote `main` and must contain all changes in the release. Record its full SHA. On the release Mac, check the mount and free space with `df -h /Volumes/eyedisk` before creating the checkout and build output.

## 3. Publish the Mac release

1. Use the repository's [Developer ID signing setup](setup.md#다른-mac에-나눠-줄-mac-앱developer-id). Check the signing team and the GitHub account for the intended release. Keep build output under `/Volumes/eyedisk/build` on the release Mac.
2. Run `scripts/release-mac.sh` to produce the Developer ID signed, notarized zip. The script checks the app signature and notarization. Check the bundle version and any entitlements changed by the release.
3. Check that the zip name matches the release version and build. Stage a byte-identical copy named `RemoteDebug.zip` for the download alias.
4. Create and push the release tag `v<version>-<build>` at the selected commit. Confirm that the remote tag resolves to that commit. Create the GitHub Release with that tag, the release notes, and both zip assets.
5. Verify that the release is published. Download both assets from the release and compare their SHA-256 digests with the verified zip. Launch the downloaded Mac app and verify the changed behavior. For changes to the bundled MCP server, verify the affected tool against that build.

For GitHub CLI publication, set `tag`, `release_zip`, `alias_zip`, and `release_notes` to the selected tag and the verified files. After confirming the remote tag, run:

```sh
gh release create "$tag" "$release_zip" "$alias_zip" --verify-tag --notes-file "$release_notes"
gh release view "$tag" --json url,tagName,isDraft,assets
```

A local export using `--no-notarize` is suitable for a local check. Public Mac releases use the notarized zip.

## 4. Verify each remaining destination

- For an iPhone release, build the agreed scheme from the selected commit. Verify that the intended recipient can obtain the advertised version and build. On the target device, confirm the installed version and run the check for the changed behavior.
- For documentation or package releases, verify the content or revision at the published branch or tag. When an app or package uses a specific version range, verify that a consumer can resolve the intended version.

If publication or verification fails, record the failed step and keep the task open. If a correction changes the app binary after publication, use a new build number for the corrected release.

## 5. Record completion

Record the following in the issue, task, or handoff used for the work.

- Landing commit and observed `origin/main` SHA.
- Release commit, version, build, and tag when applicable.
- Each release destination and the evidence that its published content or installed build was verified.
- Outstanding checks or permissions if any release destination remains open.

Use **Verified, release pending** after local verification while a merge, push, or release check remains. Mark the task complete only after all applicable checks pass.

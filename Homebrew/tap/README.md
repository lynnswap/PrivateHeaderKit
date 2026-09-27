# lynnswap Homebrew tap

Install a tool with its fully qualified formula name:

```sh
brew install lynnswap/tap/privateheaderkit
```

Update or remove it through Homebrew:

```sh
brew upgrade privateheaderkit
brew uninstall privateheaderkit
```

Each tool has its own file under `Formula/`. The shared workflows build and
check changed formulae, create bottles, and publish reviewed pull requests.
Build dependencies and functional tests belong to each formula.

To add another tool, submit its source-based formula as a pull request. To
update PrivateHeaderKit, use `privateheaderkit.rb` from its published GitHub
release. The source URL must refer to an already published version.

After the pull request checks pass, publish its bottles with `brew pr-pull`
or the **brew pr-pull** workflow. Supply the reviewed pull request head SHA
so publication uses the revision that was checked. This updates the formula's
bottle metadata and merges the pull request.

See [Homebrew's tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
for maintenance and [the Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
for package definitions.

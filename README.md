<!--
   Licensed to the Apache Software Foundation (ASF) under one
   or more contributor license agreements.  See the NOTICE file
   distributed with this work for additional information
   regarding copyright ownership.  The ASF licenses this file
   to you under the Apache License, Version 2.0 (the
   "License"); you may not use this file except in compliance
   with the License.  You may obtain a copy of the License at
     http://www.apache.org/licenses/LICENSE-2.0
   Unless required by applicable law or agreed to in writing,
   software distributed under the License is distributed on an
   "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
   KIND, either express or implied.  See the License for the
   specific language governing permissions and limitations
   under the License.
-->

<p align="center"><img width=40% src="docs/kie.svg"></p>

---

**[Apache KIE](http://kie.apache.org)** is a home for leading Open Source projects that play a role in delivering solutions around Business Automation and Artificial Intelligence in the Cloud.

[![GitHub Stars](https://img.shields.io/github/stars/apache/incubator-kie-tools.svg)](https://github.com/apache/incubator-kie-tools/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/apache/incubator-kie-tools.svg)](https://github.com/apache/incubator-kie-tools/network/members)
[![GitHub Issues](https://img.shields.io/github/issues/apache/incubator-kie-tools.svg)]()
[![Pull Requests](https://img.shields.io/github/issues-pr/apache/incubator-kie-tools.svg?style=flat-square)](https://github.com/apache/incubator-kie-tools/pulls)
[![Contributors](https://img.shields.io/github/contributors/apache/incubator-kie-tools.svg?style=flat-square)](https://github.com/apache/incubator-kie-tools/graphs/contributors)
[![License](https://img.shields.io/github/license/apache/incubator-kie-tools.svg)](https://github.com/apache/incubator-kie-tools/blob/main/LICENSE)
[![Twitter Follow](https://img.shields.io/twitter/follow/KieCommunity.svg?label=Follow&style=social)](https://twitter.com/KieCommunity?lang=en)

This repository contains tooling applications and libraries for Apache KIE projects.

## Contribute

See [CONTRIBUTING.md](./CONTRIBUTING.md)

## Build from source

#### Step 0: Install the necessary tools

> **💡 RECOMMENDED**
>
> **Nix development environment**: A _devbox_ configuration is provided to automatically setup all the tools below. Read more in [here](./repo/NIX_DEV_ENV.md).

To build and test all packages on this repository, you're going to need:

- Node.js `24` _(To install, follow these instructions: https://nodejs.org/en/download/package-manager/)_
- pnpm `10.34.4` _(To install, follow these instructions: https://pnpm.io/installation#using-npm)_
- Maven `3.9.16`
- Java `17`
- bash `5.x` _(On Linux or Nix you should be fine. On macOS, follow these instructions to use zsh: https://support.apple.com/102360)_

#### Step 1: Bootstrap

Installs the necessary 3rd party dependencies and links packages of this repository together.

- `pnpm bootstrap` --> Will bootstrap all packages
- `pnpm bootstrap [pnpm-filter]` --> Will bootstrap packages filtered by [`pnpm`-filter](https://pnpm.io/filtering)
- > E.g.,
  >
  > `pnpm bootstrap -F dmn-editor...` bootstraps the `dmn-editor` package and its dependencies.

#### Step 2: Build

- Dev

  - `pnpm -r build:dev`
    - Will build all packages for development. Skipping linters, tests, minifiers etc.
  - `pnpm [pnpm-filter] build:dev`
    - Will build packages filtered by [`pnpm`-filter](https://pnpm.io/filtering)
  - > E.g.,
    >
    > `pnpm -F dmn-editor... build:dev` builds the `dmn-editor` package and its dependencies.

- Prod

  - `pnpm -r build:prod`
    - Will build all packages for production. Optimizers will run, binaries will be produced for multiple architectures etc.
  - `pnpm [pnpm-filter] build:prod`
    - Will build packages filtered by [`pnpm`-filter](https://pnpm.io/filtering)
  - > E.g.,
    >
    > `pnpm -F dmn-editor... build:prod` builds the `dmn-editor` package and its dependencies.

- Local changes
  - `pnpm run on-affected [cmd]` (_alias for `pnpm -F '...[HEAD]'`_); or
  - `pnpm run on-affected-only [cmd]` (_alias for `pnpm -F '...^[HEAD]'`_); or
  - `pnpm run on-changed [cmd]` (_alias for `pnpm -F '[HEAD]'`_); or
  - `pnpm run on-changed-deps-only [cmd]` (_alias for `pnpm -F '[HEAD]^...'`_);
  - > E.g.,
    >
    > If you have local changes (staged or unstaged) done to the `dmn-editor` package:
    >
    > - `pnpm run on-affected build:dev`
    >   - builds the `dmn-editor` package and all packages that depend on it.
    > - `pnpm run on-affected-only build:dev`
    >   - doesn't build the `dmn-editor` package, but builds all packages that depend on it.
    > - `pnpm run on-changed build:dev`
    >   - builds the `dmn-editor` package and nothing else.
    > - `pnpm run on-changed-deps-only build:dev`
    >   - doesn't build the `dmn-editor` package, but builds all packages that it depends on.

> **ℹ️ NOTE**
>
> This repository's build is parameterized by several Environment Variables. For an extensive list of these variables, please see the list printed by the `bootstrap` step.
>
> - To enable E2E tests: `export KIE_TOOLS_BUILD__runEndToEndTests=true`

> **ℹ️ NOTE**
>
> Ubuntu 22.04 is the only OS that nativelly supports running E2E tests and by default the E2E tests will run using a Docker container. To run the tests natively in your OS please install the Playwright dependencies during the Bootstrap phase by adding the `PLAYWRIGHT_BASE__installDeps=true` environment variable. Additionally, tweak the containerized tests variable to `false` (`KIE_TOOLS_BUILD__containerizedEndToEndTests=false`). Please refer to @kie-tools/playwright-base [README](./packages/playwright-base/README.md).

> **ℹ️ NOTE**
>
> Final artifacts will be in `packages/*/dist` directories.

> **ℹ️ NOTE**
>
> For more information about how this repository works, please refer to [the `kie-tools` Manual](./repo/MANUAL.md)

---

## Reproducible Builds for _maven-based_ packages

It is mandatory that any _Maven-based_ package that releases artifacts runs [Reproducible Builds](https://reproducible-builds.org/)
to build it's artifacts, in this case, in our `build:prod` scripts.

`@kie-tools/maven-base` provides the `reproducible-build` profile to enable _Reproducible Builds_ in our builds.
To use it follow the steps:

- Make sure the `package.json` depends on `@kie-tools/maven-base`:

```json
{
  "dependencies": {
    "@kie-tools/maven-base": "workspace:*"
  }
}
```

- Make sure the package `pom.xml` has `kie-tools-maven-base` as a parent and declares the `project.build.outputTimestamp` property like:

```xml
<project>
  <parent>
    <groupId>org.kie</groupId>
    <artifactId>kie-tools-maven-base</artifactId>
    <version>${revision}</version>
    <relativePath>./node_modules/@kie-tools/maven-base/pom.xml</relativePath>
  </parent>
  ...
  <properties>
    <project.build.outputTimestamp>2024-01-12T00:00:00Z</project.build.outputTimestamp>
  </properties>
  ...
<projec>
```

- In your `package.json` scripts, enable the _Reproducible Build_ profile adding the `-Dreproducible` argument in `build:prod` scripts, like:

```json
{
  "scripts": {
    "build:prod": "pnpm lint && run-script-os",
    "build:prod:darwin:linux": "mvn clean deploy [...other maven options...] -Dreproducible",
    "build:prod:win32": "pnpm powershell \"mvn clean deploy [...other maven options...] `-Dreproducible\""
  }
}
```

> IMPORTANT: the current version of the `maven-artifact-plugin` (3.4.1) used in `kie-tools` bans the `maven-flatten-plugin` that
> we use to generate deployable artifacts using the dynamic `${revision}` variable. You can check the full list of banned
> plugins [here](https://maven.apache.org/plugins-archives/maven-artifact-plugin-3.4.1/plugin-issues.html).
> The issue that caused the ban [flatten-maven-plugin/issues/256](https://github.com/mojohaus/flatten-maven-plugin/issues/256) was a result
> of change in Maven behaviour between `v3.8.1` and `v3.8.2`, and isn't a problem on the `maven-flatten-plugin`.
> Actually, in later versions of the `maven-artifact-plugin` the ban got revoked.
> Having this in mind, and due to the fact that `kie-tools` requires newer Maven versions, our _Reproducible Builds_ require
> temporarily overriding the list of banned plugins, until we upgrade to a newer `maven-artifact-plugin` version.
> This will be addressed by https://github.com/apache/incubator-kie-issues/issues/1371

---

## Running the editors

After building (see above), the editors can be developed with Storybook. Storybook 7 fails to load `.storybook/main.ts` under Node's native TypeScript support, so on Node 22.18+/24 start it with `NODE_OPTIONS=--no-experimental-strip-types`.

| Package                           | Command      | URL                     |
| --------------------------------- | ------------ | ----------------------- |
| `packages/dmn-editor`             | `pnpm start` | `http://localhost:9901` |
| `packages/dmn-editor-standalone`  | `pnpm start` | `http://localhost:9903` |
| `packages/bpmn-editor-standalone` | `pnpm start` | `http://localhost:9904` |

Run the command from inside the package directory. Ports come from `build-env <package>.storybook.port`; the standalone `pnpm start` also rebuilds on changes.

<h1><img src="BrewPeek/Resources/AppIcon.png" alt="" width="64" height="64" align="absmiddle"> BrewPeek</h1>

**Your installed Homebrew packages, at a glance.**

BrewPeek is a macOS app for viewing and managing your installed Homebrew packages. Explore your package list, dependencies, and disk usage in one window, then update packages, uninstall them, or remove old versions.

[한국어 설명서](README.ko.md)

![BrewPeek installation overview and package list](docs/images/brewpeek-overview.png)

## Getting started

Requires an Apple Silicon Mac with Homebrew installed. Download BrewPeek from [GitHub Releases](https://github.com/kameronkim/brewpeek/releases), extract the archive, and open `BrewPeek.app`. On first launch, the package list appears after BrewPeek collects your installation information.

1. Check the overview for a summary of your installation.
2. Search or filter the list to find a package.
3. Click a package row to expand its details.
4. After making changes outside BrewPeek, click **Refresh**.

The app menus, loading messages, and native dialogs use English or Korean according to your macOS language settings, including any language preference set specifically for BrewPeek. The package inventory page is in English.

## Reading the overview

The numbers at the top summarize your current installation.

| Label | Meaning |
|---|---|
| Installed | Total number of installed formulae and casks |
| Formulae | Command-line tools, libraries, and other formula packages |
| Casks | Apps, fonts, and other packages installed as casks |
| Leaves | Formulae reported as leaves by Homebrew, useful as a starting point for reviewing dependencies |
| Taps | Additional Homebrew package repositories |

Below the overview, you can also see the number of explicitly requested formulae and the disk space used by the Cellar, where Homebrew stores formula installations.

## Finding and filtering packages

Enter a package name or description in **Search packages...**. Use **All categories** to narrow the list by category. Search, category selection, and the following filters work together.

| Filter | Shows |
|---|---|
| All | All installed packages |
| Updates | Packages with an available update; shown with a count only when updates are available |
| Formula | Formula packages |
| Cask | Cask packages |
| Leaf | Formulae marked as leaves |
| Dependency | Formulae not marked as leaves |
| Direct | Formulae recorded as explicitly requested |

The Updates filter includes both formulae and casks. If a refresh finds no available updates, it disappears and the selected Updates filter returns to All.

**Direct** describes how a formula was installed; **Leaf** describes its dependency status. A formula can have both labels.

## Inspecting a package

The package list uses the following version information and labels.

| Display | Meaning |
|---|---|
| Version | The installed version |
| Available | The new version when Homebrew reports an available update |
| DEPRECATED | A package that Homebrew has deprecated |

Click a package row to expand the following details. Click it again to collapse them.

| Field | Description |
|---|---|
| Category / Install origin | The package category and whether a formula was explicitly requested |
| Homepage / Source tap | The project's website and the repository that provides the package |
| Dependencies | Packages required by the installed package |
| Used by · Installed formulae | Installed formulae that depend on this package |
| Disk usage / Installed path | The size and location of the Homebrew installation |
| Actual app | For casks with an app bundle, the detected app's version, location, and size |

For casks, the Homebrew installation and the actual app bundle are shown separately, so you can inspect both the Caskroom record and the app itself.

## Updating packages

Click **Update** beside a package version, or **Update all** to update all available packages. Update all appears next to Refresh whenever updates are available, even if you are viewing a different filter.

BrewPeek asks Homebrew to check the changes first. The confirmation table shows each package's **Current** and **New** versions, including related dependencies. Where the relationship is known, **Required by** or **Uses** explains why a related package is included. New dependencies are marked **Not installed**. Close any apps being updated, then review the list and click **Update** to begin.

Homebrew manages the downloads and installation order. Keep BrewPeek open until the operation finishes.

If Homebrew requires administrator permission during an update or uninstall, BrewPeek asks for your macOS account password in a secure input window. The password is not saved.

## Removing packages and old versions

Open a package's details and click **Uninstall** to remove a cask or directly installed formula. Review the package and any unused dependencies before confirming. Shared and directly installed dependencies are kept.

For a formula with multiple installed versions, choose **Manage versions** to select old versions for removal. Homebrew determines which versions can be removed; versions still in use or required by other packages are kept. This action does not remove package caches or dependencies.

## Checking your environment

The **Environment** section shows your Homebrew installation prefix and version, Mac architecture, macOS version, and the disk usage of the Cellar and Caskroom. **Additional taps** lists the extra package repositories registered with Homebrew.

## Refreshing and saved data

BrewPeek shows the saved inventory when it opens, then checks current installation information and available updates using Homebrew’s rules.

Use **Refresh** after making changes outside BrewPeek. The footer shows when the displayed information was last collected.

The latest inventory is saved locally at:

```text
~/Library/Application Support/BrewPeek/inventory.json
```

Each refresh replaces the saved inventory with the latest snapshot.

## Removing BrewPeek

Open the **BrewPeek** app menu and choose **Remove BrewPeek…**. Confirm with **Move to Trash** to move the app and its saved data to Trash. Your Homebrew packages remain installed.

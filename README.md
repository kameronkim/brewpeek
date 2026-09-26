<h1><img src="BrewPeek/Resources/AppIcon.png" alt="" width="64" height="64" align="absmiddle"> BrewPeek</h1>

**Your installed Homebrew packages, at a glance.**

BrewPeek is a macOS app for exploring the command-line tools and applications installed with Homebrew. It brings your package list, dependency information, and disk usage into one window, making it easier to understand your development environment and review what you have installed.

[한국어 설명서](README.ko.md)

## Getting started

With Homebrew installed on your Mac, open `BrewPeek.app`. BrewPeek shows your saved package list first while checking for current information. On first launch, it collects your installation information before displaying the list.

1. Check the overview for a summary of your installation.
2. Search or filter the list to find a package.
3. Click a package row to expand its details.
4. After changing your Homebrew installation, click **Refresh**.

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

## Finding and sorting packages

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

Click **Name**, **Version**, or **Status** in a table header to sort the list. Click the same heading again to reverse the order. Status sorting is available for formulae. Section headings and sorting controls stay visible as you scroll through each list.

## Inspecting a package

Click a package row to expand its details. Click it again to collapse it.

The **Version** column shows the installed version. When Homebrew reports an update, a smaller **Available: version** line appears underneath.

The detail view includes:

- **Category and install origin** — The package category and whether a formula was explicitly requested.
- **Homepage and source tap** — The project's website and the repository that provides the package.
- **Dependencies** — Packages required by the installed package.
- **Used by · Installed formulae** — Installed formulae that depend on this package.
- **Disk usage and installed path** — The size and location of the Homebrew installation.
- **Actual app** — For casks with an app bundle, the detected app's version, location, and size.

For casks, the Homebrew installation and the actual app bundle are shown separately, so you can inspect both the Caskroom record and the app itself.

## Updating packages

Click **Update** beside a package version, or **Update all** to update all available packages. Update all appears next to Refresh whenever updates are available, even if you are viewing a different filter.

BrewPeek asks Homebrew to check the changes first. The confirmation table shows each package's **Current** and **New** versions, including related dependencies. Where the relationship is known, **Required by** or **Uses** explains why a related package is included. New dependencies are marked **Not installed**. Review the list and click **Update** to begin.

Homebrew manages the downloads and installation order. The progress panel shows package activity and the number processed; expand **Package details** or **Show activity** for more information. Keep BrewPeek open until the operation finishes.

BrewPeek checks installed versions before reporting the results and refreshes the inventory. Failed or skipped items can be retried. Close a running app before updating it; if administrator permission is required, **View Terminal command** provides the command to run in Terminal. After running it, return to BrewPeek and refresh.

## Checking your environment

The **Environment** section shows your Homebrew installation prefix and version, Mac architecture, macOS version, and the disk usage of the Cellar and Caskroom. **Additional taps** lists the extra package repositories registered with Homebrew.

## Refreshing and saved data

BrewPeek shows the saved inventory when it opens, then checks current installation information and new versions using Homebrew’s package information and update rules. You can search and inspect packages during a refresh; update actions become available when the check finishes. Use **Refresh** to collect it again after installing, updating, or removing packages with Homebrew. Refreshing keeps the existing page, search, filters, sort order, expanded details, and reading position. The footer shows when the displayed information was last collected. If collection fails, the saved inventory remains visible with a refresh failure status; use **Refresh** to try again.

The latest inventory is saved locally at:

```text
~/Library/Application Support/BrewPeek/inventory.json
```

Each refresh replaces the saved inventory with the latest snapshot.

## Removing BrewPeek

Open the **BrewPeek** app menu and choose **BrewPeek 제거…**. Confirm with **휴지통으로 이동** to move the app and its saved data to Trash. Your Homebrew packages remain installed.

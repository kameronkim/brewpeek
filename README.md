<img src="resources/AppIcon.png" alt="BrewPeek app icon" width="128" height="128">

# BrewPeek

**Your installed Homebrew packages, at a glance.**

BrewPeek is a macOS app for exploring the command-line tools and applications installed with Homebrew. It brings your package list, dependency information, and disk usage into one window, making it easier to understand your development environment and review what you have installed.

[한국어 설명서](README.ko.md)

## Getting started

With Homebrew installed on your Mac, open `BrewPeek.app`. BrewPeek collects your installation information and displays the package list.

1. Check the overview for a summary of your installation.
2. Search or filter the list to find a package.
3. Click a package row to expand its details.
4. After changing your Homebrew installation, click **Refresh** or press **⌘R**.

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
| Formula | Formula packages |
| Cask | Cask packages |
| Leaf | Formulae marked as leaves |
| Dependency | Formulae not marked as leaves |
| Direct | Formulae recorded as explicitly requested |

**Direct** describes how a formula was installed; **Leaf** describes its dependency status. A formula can have both labels.

Click **Name**, **Version**, or **Status** in a table header to sort the list. Click the same heading again to reverse the order. Status sorting is available for formulae. Section headings and sorting controls stay visible as you scroll through each list.

## Inspecting a package

Click a package row to expand its details. Click it again to collapse it.

The detail view includes:

- **Category and install origin** — The package category and whether a formula was explicitly requested.
- **Homepage and source tap** — The project's website and the repository that provides the package.
- **Dependencies** — Packages required by the installed package.
- **Used by · Installed formulae** — Installed formulae that depend on this package.
- **Disk usage and installed path** — The size and location of the Homebrew installation.
- **Actual app** — For casks with an app bundle, the detected app's version, location, and size.

For casks, the Homebrew installation and the actual app bundle are shown separately, so you can inspect both the Caskroom record and the app itself.

## Checking your environment

The **Environment** section shows your Homebrew installation prefix and version, Mac architecture, macOS version, and the disk usage of the Cellar and Caskroom. **Additional taps** lists the extra package repositories registered with Homebrew.

## Refreshing and saved data

BrewPeek collects information when it opens. Use **Refresh** or **⌘R** to collect it again after installing, updating, or removing packages with Homebrew. The footer shows when the displayed information was last collected.

The latest inventory is saved locally at:

```text
~/Library/Application Support/BrewPeek/inventory.json
```

Each refresh replaces the saved inventory with the latest snapshot.

## Removing BrewPeek

Open the **BrewPeek** app menu and choose **BrewPeek 제거…**. Confirm with **휴지통으로 이동** to move the app and its saved data to Trash. Your Homebrew packages remain installed.

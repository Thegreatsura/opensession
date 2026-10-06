import type { FileTree } from "@pierre/trees";
import type { PrFile } from "./types";

/** Filters navigation only. Callers continue rendering the complete diff. */
export function filterReviewFiles(
  files: PrFile[],
  query: string,
  unreviewedOnly: boolean,
  reviewedFiles?: ReadonlySet<string>,
): PrFile[] {
  const needle = query.trim().toLowerCase();
  if (!needle && !unreviewedOnly) return files;
  return files.filter(
    (file) =>
      (!unreviewedOnly || !reviewedFiles?.has(file.path)) &&
      (!needle || file.path.toLowerCase().includes(needle)),
  );
}

export function reviewFileDecoration(
  path: string,
  reviewedFiles?: ReadonlySet<string>,
  changedFiles?: ReadonlySet<string>,
): { text: string; title: string } | null {
  if (reviewedFiles?.has(path)) return { text: "✓", title: "Reviewed" };
  if (changedFiles?.has(path))
    return { text: "changed", title: "Changed since you reviewed it" };
  return null;
}

/** Every changed file under a folder in the tree. */
export function filesInFolder(
  paths: readonly string[],
  folder: string,
): string[] {
  const prefix = folder.endsWith("/") ? folder : `${folder}/`;
  return paths.filter((path) => path.startsWith(prefix));
}

/** Selection is visual only: never focuses, scrolls, or opens the diff. */
export function syncReviewTreeSelection(
  model: Pick<FileTree, "getSelectedPaths" | "getItem">,
  activeFile: string | null | undefined,
): void {
  if (activeFile === undefined) return;
  for (const path of model.getSelectedPaths()) {
    if (path !== activeFile) model.getItem(path)?.deselect();
  }
  if (activeFile) {
    const item = model.getItem(activeFile);
    if (item && !item.isDirectory() && !item.isSelected()) item.select();
  }
}

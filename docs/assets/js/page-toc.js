document.addEventListener("DOMContentLoaded", () => {
  const toc = document.getElementById("page-toc");
  const article = document.querySelector("main article");
  if (!toc || !article) return;

  const headings = article.querySelectorAll("h2, h3");
  if (!headings.length) return;

  const usedIds = new Set();
  const slugify = (text) => text.toLowerCase().trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "section";

  headings.forEach((heading) => {
    let id = heading.id || slugify(heading.textContent);
    const base = id;
    let count = 2;
    while (usedIds.has(id) || (document.getElementById(id) && document.getElementById(id) !== heading)) {
      id = `${base}-${count}`;
      count += 1;
    }
    heading.id = id;
    usedIds.add(id);
  });

  const list = toc.querySelector("ol");
  headings.forEach((heading) => {
    const item = document.createElement("li");
    if (heading.tagName === "H3") item.className = "toc-subsection";
    const link = document.createElement("a");
    link.href = `#${heading.id}`;
    link.textContent = heading.textContent;
    item.append(link);
    list.append(item);
  });
  toc.hidden = false;
});

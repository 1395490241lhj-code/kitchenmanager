export const el = (sel, root = document) => root.querySelector(sel);
export const els = (sel, root = document) => Array.from(root.querySelectorAll(sel));

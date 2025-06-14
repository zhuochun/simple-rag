function textToLightColor(text) {
    let hash = 0;
    for (let i = 0; i < text.length; i++) {
        hash = text.charCodeAt(i) + ((hash << 5) - hash);
    }
    let r = (hash & 0xFF) % 64 + 192; // 192-255
    let g = ((hash >> 8) & 0xFF) % 64 + 192;
    let b = ((hash >> 16) & 0xFF) % 64 + 192;
    return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
}

function applyBackgroundColor(element, text) {
    element.style.backgroundColor = textToLightColor(text);
}

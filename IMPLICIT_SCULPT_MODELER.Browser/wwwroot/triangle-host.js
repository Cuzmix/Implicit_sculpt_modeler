const triangleCanvases = new Map();

export function createTriangleCanvas(hostElement, canvasId) {
    const canvas = document.createElement("canvas");
    canvas.id = canvasId;
    canvas.style.width = "100%";
    canvas.style.height = "100%";
    canvas.style.display = "block";
    canvas.style.touchAction = "none";
    canvas.style.background = "#0a0d12";

    hostElement.replaceChildren(canvas);
    triangleCanvases.set(canvasId, canvas);
    return canvas;
}

export function destroyTriangleCanvas(canvasId) {
    const canvas = triangleCanvases.get(canvasId);
    if (!canvas) {
        return;
    }

    canvas.remove();
    triangleCanvases.delete(canvasId);
}

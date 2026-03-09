/**
 * upload_bridge.js
 *
 * Provides the two globals that upload_panel.gd expects on web builds:
 *   window.godotUploadQueue       – Array<{name, base64, error?}>
 *   window.godotUploadOpenPicker() – opens the browser file picker
 *
 * Include this script in the exported HTML BEFORE the Godot engine boots.
 * In Godot's Web export settings → HTML → "Head Include", add:
 *   <script src="upload_bridge.js"></script>
 *
 * Then copy this file into the same folder as the exported .html file.
 *
 * Drag-and-drop onto the Godot canvas is also supported automatically.
 */

(function () {
  "use strict";

  // Queue polled every frame by upload_panel.gd via JavaScriptBridge.eval().
  window.godotUploadQueue = [];

  // Called by upload_panel.gd when the user clicks the Upload button.
  window.godotUploadOpenPicker = function () {
    var input = document.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.accept = ".sch,.spice,.cir,.net,.txt";

    input.addEventListener("change", function (e) {
      var files = Array.from(e.target.files || []);
      files.forEach(_readAndQueue);
      // Clean up the hidden input after use.
      if (input.parentNode) {
        input.parentNode.removeChild(input);
      }
    });

    // Must be in the DOM for some browsers to fire the change event.
    input.style.display = "none";
    document.body.appendChild(input);
    input.click();
  };

  // Reads a File object and pushes {name, base64} onto the queue.
  function _readAndQueue(file) {
    var reader = new FileReader();

    reader.onload = function (ev) {
      var buffer = ev.target.result; // ArrayBuffer
      var bytes = new Uint8Array(buffer);

      // Convert to base64 in chunks to avoid stack overflow on large files.
      var CHUNK = 8192;
      var binary = "";
      for (var i = 0; i < bytes.length; i += CHUNK) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
      }
      var b64 = btoa(binary);

      window.godotUploadQueue.push({ name: file.name, base64: b64 });
    };

    reader.onerror = function () {
      var msg = reader.error ? reader.error.message : "unknown error";
      window.godotUploadQueue.push({ name: file.name, base64: "", error: msg });
    };

    reader.readAsArrayBuffer(file);
  }

  // Wire up drag-and-drop onto the Godot canvas once the page is ready.
  function _setupDragDrop() {
    // Godot 4 web export uses id="canvas" by default.
    var canvas = document.getElementById("canvas");
    if (!canvas) {
      // Try again after a short delay in case Godot hasn't inserted the canvas yet.
      setTimeout(_setupDragDrop, 500);
      return;
    }

    canvas.addEventListener("dragover", function (e) {
      e.preventDefault();
      e.stopPropagation();
      e.dataTransfer.dropEffect = "copy";
    });

    canvas.addEventListener("drop", function (e) {
      e.preventDefault();
      e.stopPropagation();
      var files = Array.from(e.dataTransfer.files || []);
      files.forEach(_readAndQueue);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", _setupDragDrop);
  } else {
    _setupDragDrop();
  }
})();

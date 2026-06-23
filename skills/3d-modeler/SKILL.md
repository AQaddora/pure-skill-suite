---
name: 3d-modeler
description: "Generates 3D interior models from photos and injects them into Mapbox GL JS map instances."
version: "1.0.0"
author: "Ahmed Qaddoura"
dependencies:
  - "@lumaai/luma-web" # Or whatever the chosen API requires
  - "three"
  - "threebox-plugin"
---

# 3D Modeler Skill

This skill allows agents to convert photographs of interiors into 3D models (GLB/GLTF) and inject them into web-based Mapbox 3D styles using Three.js and the Threebox plugin.

## Capabilities
1. **Photo-to-3D Generation**: Uses `photoTo3D.js` to call 3D reconstruction APIs (e.g., Luma AI / Polycam) to process an image and return a URL to a GLB file.
2. **Mapbox Injection Prep**: Uses `mapboxInjector.js` to prepare a GLB file for Mapbox insertion, calculating the necessary MercatorCoordinates and Three.js scale/rotation matrices to align the interior model perfectly with the real-world map.

## Usage
When a user uploads a photo of a room and asks to place it on the map, trigger this skill:
1. Pass the image URL to `photoTo3D.js`. Wait for the 3D generation to complete.
2. Pass the resulting GLB URL and target LngLat coordinates to `mapboxInjector.js` to get the integration payload.
3. Send the payload back to the frontend to render the model inside the Mapbox custom layer.

/**
 * mapboxInjector.js
 * 
 * Prepares the payload needed by the frontend to inject a GLB model into a Mapbox GL JS
 * custom layer using Three.js / Threebox.
 */

function createMapboxInjectionPayload(glbUrl, lngLat, options = {}) {
  const {
    elevation = 0,    // Altitude in meters
    scale = 1,        // Uniform scale multiplier
    rotation = { x: 90, y: 0, z: 0 } // Default rotation to stand the model upright
  } = options;

  console.log(`[3D Modeler] Preparing Mapbox injection payload for ${glbUrl} at [${lngLat[0]}, ${lngLat[1]}]`);

  // Mapbox frontend will need these exact parameters to sync the Three.js camera
  // and position the object using mercator coordinates.
  return {
    action: "inject_3d_model",
    target: "mapbox_custom_layer",
    payload: {
      url: glbUrl,
      position: {
        lng: lngLat[0],
        lat: lngLat[1],
        alt: elevation
      },
      transform: {
        scale: scale,
        rotation: rotation
      },
      // Frontend code snippet for execution using Threebox:
      // window.tb.loadObj({ obj: payload.url, type: 'gltf', scale: payload.transform.scale, units: 'meters', rotation: payload.transform.rotation })
      //   .then(model => {
      //     model.setCoords([payload.position.lng, payload.position.lat, payload.position.alt]);
      //     window.tb.add(model);
      //   });
    }
  };
}

module.exports = {
  createMapboxInjectionPayload
};

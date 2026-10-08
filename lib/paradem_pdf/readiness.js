(async () => {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('PDF readiness timeout')), READINESS_TIMEOUT);
  });
  try {
    const resources = (async () => {
      const images = Array.from(document.images);
      images.forEach(image => { image.loading = 'eager'; });
      const decoded = images.map(async image => {
        try {
          await image.decode();
          if (!image.naturalWidth) throw new Error('No intrinsic width');
        } catch (_) {
          throw new Error(`PDF image failed: ${image.currentSrc || image.src}`);
        }
      });
      // Layout requests fonts in the media already selected by the caller.
      void document.body.offsetHeight;
      const fonts = (async () => {
        try {
          await document.fonts.ready;
          for (const face of document.fonts) {
            if (face.status === 'error') throw new Error('Font face error');
          }
        } catch (_) {
          throw new Error('PDF font failed');
        }
      })();
      await Promise.all([...decoded, fonts]);
    })();
    await Promise.race([resources, deadline]);
  } finally {
    clearTimeout(timer);
  }
})()

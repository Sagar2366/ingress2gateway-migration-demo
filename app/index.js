const express = require('express');
const app = express();
const port = process.env.PORT || 3000;

app.get('/hello', (req, res) => {
  // Detect controller: Istio adds x-envoy headers, nginx adds x-real-ip
  const controller = req.headers['x-envoy-decorator-operation'] ? 'Gateway API' : 'Nginx Ingress';
  res.json({ 
    message: `Hello from ${controller}!`
  });
});

app.get('/goodbye', (req, res) => {
  const controller = req.headers['x-envoy-decorator-operation'] ? 'Gateway API' : 'Nginx Ingress';
  res.json({ 
    message: `Goodbye from ${controller}!`
  });
});

app.get('/', (req, res) => {
  res.send('Try /hello and /goodbye');
});

app.listen(port, () => {
  console.log(`App listening on port ${port}`);
});

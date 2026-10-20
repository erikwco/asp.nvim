// Biblioteca de pagina.asp, cargada por <script src>.
function desdeSrc() {
  return interno();
}

function interno() { return 1; }

function duplicada() { return 'src'; }

function conLocal() {
  var desdeInclude = 0;
  return desdeInclude;
}

var deLaPagina = 2;
desdeSrc();

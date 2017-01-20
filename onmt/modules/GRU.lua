require('nngraph')

--[[
Implementation of a single stacked-GRU step as
an nn unit.

      h^L_{t-1} --- h^L_t
                 |


                 .
                 |
             [dropout]
                 |
      h^1_{t-1} --- h^1_t
                 |
                 |
                x_t

Computes $$(h_{t-1}, x_t) => (h_{t})$$.

--]]
local GRU, parent = torch.class('onmt.GRU', 'onmt.Network')

--[[
Parameters:

  * `layers` - Number of LSTM layers, L.
  * `inputSize` - Size of input layer
  * `hiddenSize` - Size of the hidden layers.
  * `dropout` - Dropout rate to use.
  * `residual` - Residual connections between layers.
--]]
function GRU:__init(layers, inputSize, hiddenSize, dropout, residual)
  dropout = dropout or 0

  self.dropout = dropout
  self.numEffectiveLayers = layers
  self.outputSize = hiddenSize

  parent.__init(self, self:_buildModel(layers, inputSize, hiddenSize, dropout, residual))
end

--[[ Stack the GRU units. ]]
function GRU:_buildModel(layers, inputSize, hiddenSize, dropout, residual)
  local inputs = {}
  local outputs = {}

  for _ = 1, layers do
    table.insert(inputs, nn.Identity()()) -- h0: batchSize x hiddenSize
  end

  table.insert(inputs, nn.Identity()()) -- x: batchSize x inputSize
  local x = inputs[#inputs]

  local prevInput
  local nextH

  for L = 1, layers do
    local input
    local inputDim

    if L == 1 then
      -- First layer input is x.
      input = x
      inputDim = inputSize
    else
      inputDim = hiddenSize
      input = nextH
      if residual and (L > 2 or inputSize == hiddenSize) then
        input = nn.CAddTable()({input, prevInput})
      end
      if dropout > 0 then
        input = nn.Dropout(dropout)(input)
      end
    end

    local prevH = inputs[L]

    nextH = self:_buildLayer(inputDim, hiddenSize)({prevH, input})
    prevInput = input

    table.insert(outputs, nextH)
  end

  return nn.gModule(inputs, outputs)
end

--[[ Build a single GRU unit layer.
    .. math::

            \begin{array}{ll}
            r_t = sigmoid(W_{xr} x_t + b_{xr} + W_{hr} h_{(t-1)} + b_{hr}) \\
            i_t = sigmoid(W_{xi} x_t + b_{xi} + W_hi h_{(t-1)} + b_{hi}) \\
            n_t = \tanh(W_{xn} x_t + b_{xn} + r_t * (W_{hn} h_{(t-1)} + b_{hn}) \\
            h_t = (1 - i_t) * n_t + i_t * h_{(t-1)} = n_t + i_t * (h_{(t-1)-n}) \\
            \end{array}

    where :math:`h_t` is the hidden state at time `t`, :math:`x_t` is the hidden
    state of the previous layer at time `t` or :math:`input_t` for the first layer,
    and :math:`r_t`, :math:`i_t`, :math:`n_t` are the reset, input, and new gates, respectively.

    In the function `prevH`=:math:`h_{(t-1}}`, `nextH`=:math:`h_t`
]]
function GRU:_buildLayer(inputSize, hiddenSize)
  local inputs = {}
  table.insert(inputs, nn.Identity()())
  table.insert(inputs, nn.Identity()())

  -- recurrent input
  local prevH = inputs[1]
  -- previous layer input
  local x = inputs[2]

  -- Evaluate the input sums at once for efficiency.
  local x2h = nn.Linear(inputSize, 3 * hiddenSize)(x)
  local h2h = nn.Linear(hiddenSize, 3 * hiddenSize)(prevH)

  -- extract Wxr.x+bir, Wxi.x+bxi, Wxn.x+bin
  local x2h_reshaped = nn.Reshape(3, hiddenSize)(x2h)
  local x2h_r, x2h_i, x2h_n = nn.SplitTable(2)(x2h_reshaped):split(3)

  -- extract Whr.x+bhr, Whi.x+bhi, Whn.x+bhn
  local h2h_reshaped = nn.Reshape(3, hiddenSize)(h2h)
  local h2h_r, h2h_i, h2h_n = nn.SplitTable(2)(h2h_reshaped):split(3)

  -- Decode the gates.
  local r = nn.Sigmoid()(nn.CAddTable()({x2h_r, h2h_r}))
  local i = nn.Sigmoid()(nn.CAddTable()({x2h_i, h2h_i}))
  local n = nn.Tanh()(nn.CAddTable()({
    x2h_n, nn.CMulTable()({r, h2h_n})
  }))

  -- Perform the GRU update.
  local nextH = nn.CAddTable()({
    n,
    nn.CMulTable()({i, nn.CAddTable()({prevH, nn.MulConstant(-1)(n)})})
  })

  return nn.gModule(inputs, {nextH})
end
local Transform3DPoints_Rt, parent = torch.class('nn.Transform3DPoints_Rt', 'nn.Module')

--[[

   PinHoleCameraProjectionBHWD(height, width) :
   PinHoleCameraProjectionBHWD:updateOutput(transformMatrix)
   PinHoleCameraProjectionBHWD:updateGradInput(transformMatrix, gradGrids)

   PinHoleCameraProjectionBHWD will take 2x3 an affine image transform matrix (homogeneous 
   coordinates) as input, and output a grid, in normalized coordinates* that, once used
   with the Bilinear Sampler, will result in an affine transform.

   PinHoleCameraProjection 
   - takes (B,2,3)-shaped transform matrices as input (B=batch).
   - outputs a grid in BHWD layout, that can be used directly with BilinearSamplerBHWD
   - initialization of the previous layer should biased towards the identity transform :
      | 1  0  0 |
      | 0  1  0 |

   *: normalized coordinates [-1,1] correspond to the boundaries of the input image. 

]]--

function Transform3DPoints_Rt:__init(height, width, fx, fy, u0, v0)
  parent.__init(self)
  
   assert(height > 1)
   assert(width > 1)

   self.height = height
   self.width  = width
   
   self.fx = fx 
   self.fy = fy 

   self.u0 = u0 
   self.v0 = v0  
 
   self.gradInput = {}  
 
   self.baseGrid = torch.Tensor(height, width, 4)
   
   for i=1,self.height do
      self.baseGrid:select(3,2):select(1,i):fill( (i-self.v0)/self.fy )
   end
   
   for j=1,self.width do
      self.baseGrid:select(3,1):select(2,j):fill( (j-self.u0)/self.fx )
   end
   
   self.baseGrid:select(3,3):fill(1)
   self.baseGrid:select(3,4):fill(1)

   self.batchGrid = torch.Tensor(1, height, width, 4):copy(self.baseGrid)

   self.points3D  = torch.Tensor(1, height, width, 4):fill(1)

   self.gradInput[1] = torch.Tensor(1)
   self.gradInput[2] = torch.Tensor(1)

      --- do d * R * [x y z] -- + t                
   self.deriv = torch.Tensor(1, self.height, self.width, 4):zero()

   --- This should be changed to [ (u-u0)/fx, (v-v0)/fy, 1]
   self.deriv:select(4,1):copy(self.baseGrid:select(3,1))
   self.deriv:select(4,2):copy(self.baseGrid:select(3,2))
   self.deriv:select(4,3):copy(self.baseGrid:select(3,3))

 
  
end

function Transform3DPoints_Rt:updateOutput(transformMatrix_and_depths)

   _transformMatrix, depths = unpack(transformMatrix_and_depths)

   local transformMatrix = _transformMatrix

   assert(transformMatrix:nDimension()==3
          and transformMatrix:size(2)==3
          and transformMatrix:size(3)==4
          , 'please input transformation matrix of size (bx3x4)')
 
   local batchsize = transformMatrix:size(1)

   if self.points3D:size(1) ~= batchsize then 
	self.points3D:resize(batchsize,self.height,self.width,4)
	self.points3D:fill(1)
   end
  
   for b = 1, batchsize do

	   --[[ (u-u0)/fx, (v-v0)/fy, 1 ]]--	  
	   local u_minus_u0 = self.baseGrid:select(3,1)
	   local v_minus_v0 = self.baseGrid:select(3,2)
	 
	   local u_times_depth = torch.cmul(u_minus_u0,depths[b])	
	   local v_times_depth = torch.cmul(v_minus_v0,depths[b])	

           self.points3D[b]:select(3,1):copy(u_times_depth) 	
	   self.points3D[b]:select(3,2):copy(v_times_depth)
	   self.points3D[b]:select(3,3):copy(depths[b]) 	

   end
     
   local flattenedBatchGrid  = self.points3D:view(batchsize, self.width*self.height, 4)
   local flattenedOutput     = torch.Tensor(batchsize, self.width*self.height, 3):typeAs(depths):zero()

   -- Matrix multiplication of 3x4 matrix with 4x1 homogenous points 
   torch.bmm(flattenedOutput, flattenedBatchGrid, transformMatrix:transpose(2,3))

   -- 3D points
   self.output = flattenedOutput:view(batchsize,self.height,self.width,3)
  
   
   if _transformMatrix:nDimension()==2 then
      self.output = self.output:select(1,1)
   end
  
   return self.output

end

function Transform3DPoints_Rt:updateGradInput(_input, _gradGrid)
   
   --_transformMatrix, depths = unpack(transformMatrix_and_depths)

   local tM3x4  = _input[1]
   local depths = _input[2]  

   local gradGrid = _gradGrid

   local batchsize         = tM3x4:size(1)
   local flattenedGradGrid = gradGrid:view(batchsize, self.width*self.height, 3)

   local points3D = self.points3D:view(batchsize, self.width*self.height, 4)
   local input    = {tM3x4, depths}

   if batchsize > 1 then

	self.deriv:resize(batchsize, self.height, self.width,4)
	self.deriv:fill(0)

	for b =1, batchsize do

           self.deriv[b]:select(3,1):copy(self.baseGrid:select(3,1))
   	   self.deriv[b]:select(3,2):copy(self.baseGrid:select(3,2))
   	   self.deriv[b]:select(3,3):copy(self.baseGrid:select(3,3))

	end
	
   end 

   --- just for declaration and copying the size
   self.gradInput[1]:resizeAs(tM3x4):typeAs(tM3x4):zero() 

   --- just for declaration and copying the size
   self.gradInput[2]:resizeAs(depths):typeAs(depths):zero()
   
   --- derivative with respect to the transformation matrix
   torch.bmm(self.gradInput[1],flattenedGradGrid:transpose(2,3), points3D)


   --- saving the grads with respect to the transformed 3d points
   local x1 = gradGrid:select(4,1)
   local x2 = gradGrid:select(4,2)
   local x3 = gradGrid:select(4,3)

   --- do d * R * [x y z] -- + t                
   -- local Rp = torch.Tensor(batchsize, self.height, self.width, 4):zero()

   -- This should be changed to [ (u-u0)/fx, (v-v0)/fy, 1]
   -- Rp:select(4,1):copy(self.baseGrid:select(3,1))
   -- Rp:select(4,2):copy(self.baseGrid:select(3,2))
   -- Rp:select(4,3):copy(self.baseGrid:select(3,3))

   local Rpt = torch.bmm(self.deriv:view(batchsize, self.height*self.width,4), tM3x4:transpose(2,3))
   Rpt = Rpt:view(batchsize, self.height, self.width, 3)

   local y1 = Rpt:select(4,1)
   local y2 = Rpt:select(4,2)
   local y3 = Rpt:select(4,3)

   self.gradInput[2] = torch.add(torch.add(torch.cmul(x1,y1),torch.cmul(x2,y2)),torch.cmul(x3,y3))

   return self.gradInput

end

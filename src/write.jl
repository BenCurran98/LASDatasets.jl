"""
    $(TYPEDSIGNATURES)

Saves a pointcloud to LAS or LAZ. The appropriate LAS version and point format is inferred from the contents of your point cloud

# Arguments
* `file_name` : Name of the LAS file to save the data into
* `pointcloud` : Point cloud data in a tabular format

### Keyword Arguments
* `vlrs` : Collection of Variable Length Records to write to the LAS file, default `LasVariableLengthRecord[]`
* `evlrs` : Collection of Extended Variable Length Records to write to the LAS file, default `LasVariableLengthRecord[]`
* `user_defined_bytes` : Any user-defined bytes to write in between the VLRs and point records, default `UInt8[]`
* `scale` : Scaling factor applied to points on writing, default `LASDatasets.POINT_SCALE`
---
$(METHODLIST)
"""
function save_las(file_name::AbstractString, pointcloud::AbstractVector{<:NamedTuple}; 
                        vlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[], 
                        evlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[], 
                        user_defined_bytes::Vector{UInt8} = UInt8[],
                        scale::Real = POINT_SCALE,
                        kwargs...)
    open_func = get_open_func(file_name)
    open_func(file_name, "w") do io
        write_las(io, pointcloud, vlrs, evlrs, user_defined_bytes, scale)
    end
end

function save_las(file_name::AbstractString, las::LASDataset)
    open_func = get_open_func(file_name)
    open_func(file_name, "w") do io
        write_las(io, las)
    end
end

function save_las(file_name::AbstractString, 
                    header::LasHeader, 
                    point_records::Vector{TRecord}, 
                    vlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[], 
                    evlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[], 
                    user_defined_bytes::Vector{UInt8} = UInt8[],
                    scale::Real = POINT_SCALE) where {TRecord <: LasRecord}
    open_func = get_open_func(file_name)
    open_func(file_name, "w") do io
        write_las(io, header, point_records, vlrs, evlrs, user_defined_bytes, scale)
    end
end

function write_las(io::IO, pointcloud::AbstractVector{<:NamedTuple},
                    vlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[], 
                    evlrs::Vector{<:LasVariableLengthRecord} = LasVariableLengthRecord[], 
                    user_defined_bytes::Vector{UInt8} = UInt8[],
                    scale::Real = POINT_SCALE)
    point_format = get_point_format(pointcloud)
    write_las(io, pointcloud, point_format, vlrs, evlrs, user_defined_bytes, scale)
end


"""
    $(TYPEDSIGNATURES)

Write a pointcloud and additional VLR's and user-defined bytes to an IO stream in a LAS format

# Arguments
* `io` : IO channel to write the data to
* `pointcloud` : Pointcloud data in a tabular format to write
* `vlrs` : Collection of Variable Length Records to write to `io`
* `evlrs` : Collection of Extended Variable Length Records to write to `io`
* `user_defined_bytes` : Any user-defined bytes to write in between the VLRs and point records
* `scale` : Scaling factor applied to points on writing
"""
function write_las(io::IO, pointcloud::AbstractVector{<:NamedTuple}, 
                    point_format::Type{TPoint},
                    vlrs::Vector{<:LasVariableLengthRecord}, 
                    evlrs::Vector{<:LasVariableLengthRecord}, 
                    user_defined_bytes::Vector{UInt8},
                    scale::Real) where {TPoint}
    # automatically construct a header that's consistent with the data and point format we've supplied
    header = make_consistent_header(pointcloud, point_format, vlrs, evlrs, user_defined_bytes, scale)
    write_las(io, LASDataset(header, pointcloud, vlrs, evlrs, user_defined_bytes))
end

function write_las(io::IO, las::LASDataset)
    header = get_header(las)
    vlrs = get_vlrs(las)
    
    pc = get_pointcloud(las)

    # reverse our unit conversion done on ingest so the positions match the header / VLR info
    if get_unit_conversion(las) != NO_CONVERSION
        pc.position .= map(p -> p ./ get_unit_conversion(las), pc.position)
    end


    this_point_format = point_format(header)
    xyz = spatial_info(header)

    cols = collect(columnnames(pc))
    these_are_las_cols = cols .∈ Ref(RECOGNISED_LAS_COLUMNS)
    other_cols = cols[.!these_are_las_cols]
    user_fields = filter(c -> c != :undocumented_bytes, other_cols)

    write(io, header)

    @info "POST HEADER: $(position(io))"
    @show header_size(header)

    for vlr ∈ vlrs
        write(io, vlr)
    end

    @info "POST VLRS: $(position(io))"

    write(io, get_user_defined_bytes(las))

    @info "POST USER DEFINED: $(position(io))"
    @show point_data_offset(header)

    undoc_bytes = :undocumented_bytes ∈ columnnames(pc) ? pc.undocumented_bytes : fill(SVector{0, UInt8}(), length(pc))

    # packing points into a StructVector makes operations where you have to access per-point fields many times like in get_record_bytes below faster
    las_records = StructVector(las_record.(this_point_format, pc, Ref(xyz), undoc_bytes, Ref(user_fields)); unwrap = t -> (t <: LasPoint) || (t <: UserFields))
    byte_vector = get_record_bytes(las_records, vlrs)
    write(io, byte_vector)

    @info "POST POINTS: $(position(io))"
    @show evlr_start(header)

    for evlr ∈ get_evlrs(las)
        write(io, evlr)
    end

    @info "FINAL: $(position(io))"

    return nothing
end

"""
    $(TYPEDSIGNATURES)

Construct an array of bytes that correctly encodes the information stored in a set of LAS `records` according to the spec
"""
function get_record_bytes(records::StructVector{TRecord}, vlrs::Vector{LasVariableLengthRecord}) where {TRecord <: LasRecord}
    point_format = get_point_format(TRecord)
    point_fields = collect(fieldnames(point_format))
    bytes_per_point_field = sizeof.(fieldtypes(point_format))
    user_field_bytes = get_num_user_field_bytes(TRecord)
    undoc_bytes = get_num_undocumented_bytes(TRecord)
    
    bytes_per_record = sum(bytes_per_point_field) + user_field_bytes + undoc_bytes

    total_num_bytes = length(records) * bytes_per_record
    whole_byte_vec = Vector{UInt8}(undef, total_num_bytes)
    byte_offset = 0
    lazy = LazyRows(records)
    field_idxs = Dict()
    for (i, field) ∈ enumerate(point_fields)
        field_byte_vec = reinterpret(UInt8, getproperty(lazy.point, field))
        if bytes_per_point_field[i] ∉ keys(field_idxs)
            field_idxs[bytes_per_point_field[i]] = reduce(vcat, map(j -> (0:bytes_per_point_field[i] - 1) .+ j, 1:bytes_per_record:total_num_bytes))
        end
        this_field_idxs = byte_offset > 0 ? field_idxs[bytes_per_point_field[i]] .+ byte_offset : field_idxs[bytes_per_point_field[i]]
        view(whole_byte_vec, this_field_idxs) .= field_byte_vec
        byte_offset += bytes_per_point_field[i]
    end

    if user_field_bytes > 0
        # need to write the extra bytes fields in the same order as they appear in the VLR
        extra_bytes_vlr = extract_vlr_type(vlrs, LAS_SPEC_USER_ID, ID_EXTRABYTES)
        @assert !isnothing(extra_bytes_vlr) "Expected to find an Extra Bytes VLR but found none!"
        # get the order they appear in the VLR
        user_field_names = unique(get_base_field_name.(Symbol.(name.(get_extra_bytes(get_data(extra_bytes_vlr))))))
        # create a mapping between the order in the VLR and the order in the record
        per_record_user_field_names = get_user_field_names(TRecord)
        user_field_idxs = indexin(user_field_names, collect(per_record_user_field_names))
        user_field_types = get_user_field_types(TRecord)
        bytes_per_user_field = sizeof.(user_field_types)
        for (i, user_field) ∈ enumerate(user_field_names)
            field_byte_vec = reinterpret(UInt8, getproperty(lazy.user_fields, user_field))
            idx = user_field_idxs[i]
            if bytes_per_user_field[idx] ∉ keys(field_idxs)
                field_idxs[bytes_per_user_field[idx]] = reduce(vcat, map(j -> (0:bytes_per_user_field[idx] - 1) .+ j, 1:bytes_per_record:total_num_bytes))
            end
            this_field_idxs = field_idxs[bytes_per_user_field[idx]] .+ byte_offset
            view(whole_byte_vec, this_field_idxs) .= field_byte_vec
            byte_offset += bytes_per_user_field[idx]
        end
    end

    if undoc_bytes > 0
        undoc_idxs = reduce(vcat, map(j -> (0:undoc_bytes - 1) .+ j, (byte_offset + 1):bytes_per_record:total_num_bytes))
        view(whole_byte_vec, undoc_idxs) .= reduce(vcat, map(u -> Vector(u), Base.getproperty(records, :undoc_bytes)))
    end
    
    return whole_byte_vec
end
/* Generated from orogen/lib/orogen/templates/typekit/smart_ptr.cpp */

<%= into.arg_type %> orogen_typekits::toIntermediate(<%= from.arg_type %> real_type)
{
    return *real_type;
}
bool orogen_typekits::fromIntermediate(<%= from.ref_type %> real_type, <%= into.cxx_name %>* intermediate)
{
    if (real_type.get() != intermediate)
        real_type.reset(intermediate);
    return true; // the smart pointer took ownership of the pointer
}
